
require 'jenkins/configuration'
require 'jenkins/version'
require 'jenkins_api_client'
require 'tmpdir'
require 'fileutils'
require 'libarchive'
require 'yaml'

module Jenkins
  class Backup
    attr_accessor *Configuration::VALID_PARAMS

    def initialize(params = {})
      params = Jenkins.params.merge(params)
      Configuration::VALID_PARAMS.each do |key|
        send("#{key}=", params[key])
      end
      @client = JenkinsApi::Client.new(
        :server_ip => server_ip,
        :username => username,
        :password => password
      )
    end

    def backup(name = "jenkins", options = {})
      puts "Creating a backup of Jenkins Configuration from #{server_ip}"
      metadata = {:jobs => {}}

      # General information about backup
      timestamp = Time.now
      start_time = timestamp
      metadata[:timestamp] = timestamp
      metadata[:created_by] = username
      metadata[:server_ip] = server_ip
      metadata[:server_port] = server_port || 8080
      metadata[:tool_version] = Jenkins::VERSION
      metadata[:contents] = "jobs"

      tmp_dir = Dir.mktmpdir

      # Collect information about Jobs
      jobs_dir = "#{tmp_dir}/jobs"
      Dir.mkdir(jobs_dir)
      jobs = @client.job.list_all
      metadata[:jobs][:count] = jobs.length
      metadata[:jobs][:names] = jobs

      # Obtain xml configuration of all jobs
      jobs.each do |job|
        puts "Obtaining xml for #{job}"
        xml = @client.job.get_config(job)
        File.open("#{jobs_dir}/#{job}.xml", "w") { |f| f.write(xml) }
      end

      # Collect information Views
      views_dir = "#{tmp_dir}/views"
      Dir.mkdir(views_dir)
      views = @client.view.list
      metadata[:views] = {}
      # Number of views. Don't consider "All". It is the default view.
      metadata[:views][:count] = views.length - 1
      metadata[:views][:details] = []

      # Obtain specific attributes of each view so it can be created in jenkins
      # with the same configuration. Posting config.xml to view doesn't seem to
      # be working now. So let's just create the view by giving all required
      # attributes.
      views.each do |view|
        next if view == "All"
        puts "Obtaining xml for #{view}"
        xml = @client.view.get_config(view)
        File.open("#{views_dir}/#{view}.xml", "w") { |f| f.write(xml) }
        job_names = @client.view.list_jobs(view)

        # Filter Queue attribute
        filter_queue = xml.match(/<filterQueue>(.*)<\/filterQueue>/)
        filter_queue = (filter_queue[1] unless filter_queue.nil?)

        # Filter Executors attribute
        filter_executors = xml.match(/<filterExecutors>(.*)<\/filterExecutors>/)
        filter_executors = (filter_executors[1] unless filter_executors.nil?)

        # Regex attribute for jobs
        regex = xml.match(/<includeRegex>(.*)<\/includeRegex>/)
        regex = (regex[1] unless regex.nil?)

        # Jobs in view that are not matched by regular expression. Any job can
        # be added to a view, not just the ones that match the regex provided.
        # So if there are jobs that don't match the regex, those should be
        # captured separately so they can be added when the backup is restored.
        # So just list all jobs in a view and skip the ones that match the
        # regex as they will get added by Jenkins as we mention the regex
        # attribute while creation.
        unmatched_jobs = []
        job_names.each do |job|
          unless regex && job =~ /#{regex}/
            unmatched_jobs << job
          end
        end

        # Construct the metadata for specific attributes of a view. If a
        # particular attribute is not found in the view, its value will be nil,
        # so during restore, if a particular value is nil it should be passed
        # in to the create call so the default value will be chosen by the
        # jenkins api client.
        metadata[:views][:details] << {
          :view_name => view,
          :filter_queue => filter_queue,
          :filter_executors => filter_executors,
          :regex => regex,
          :job_names => unmatched_jobs
        }
      end

      # Write metadata as a YAML file
      File.open("#{tmp_dir}/metadata.yml", "w") { |f| f.write(metadata.to_yaml) }

      # Open the archive
      archive_name = "#{name}-#{timestamp.to_i}.tar.gz"
      archive = Archive.write_open_filename(
        archive_name,
        Archive::COMPRESSION_GZIP,
        Archive::FORMAT_TAR
      )
      write_xml_to_archive(archive, jobs_dir, tmp_dir)
      write_xml_to_archive(archive, views_dir, tmp_dir)
      metadata_fn = "#{tmp_dir}/metadata.yml"
      archive.new_entry do |entry|
        entry.copy_stat(metadata_fn)
        entry.pathname = "metadata.yml"
        archive.write_header(entry)
        archive.write_data(open(metadata_fn) { |f| f.read})
      end
      # Close the archive
      archive.close
      FileUtils.rm_rf(tmp_dir)
      puts metadata.inspect

      end_time = Time.now

      puts "Backup complete! Time took: #{end_time - start_time} seconds."
      archive_name
    end

    def restore(name, options = {})

      start_time = Time.now
      tmp_dir = Dir.mktmpdir
      puts "Temp dir: #{tmp_dir}"
      jobs_dir = "#{tmp_dir}/jobs"
      Dir.mkdir(jobs_dir)

      views_dir = "#{tmp_dir}/views"
      Dir.mkdir(views_dir)

      puts "Restoring backup to Jenkins"
      Archive.read_open_filename(name) do |ar|
        while entry = ar.next_header
          name = entry.pathname
          data = ar.read_data
          File.open("#{tmp_dir}/#{name}", "w") { |f| f.write(data) }
        end
      end
      metadata = YAML.load_file("#{tmp_dir}/metadata.yml")
      puts metadata.inspect

      # Create jobs
      restore_jobs(jobs_dir, metadata[:jobs], options)

      # Restore views
      restore_views(views_dir, metadata[:views], options)
      # Get rid of the temp directory
      FileUtils.rm_rf(tmp_dir)

      end_time = Time.now
      puts "Restore complete! Time took: #{end_time - start_time} seconds."
    end

    private

    def write_xml_to_archive(archive, xml_dir, tmp_dir)
      Dir.glob("#{xml_dir}/*xml").each do |fn|
        short_name = fn.split("#{tmp_dir}/").last
        archive.new_entry do |entry|
          entry.copy_stat(fn)
          entry.pathname = short_name
          archive.write_header(entry)
          archive.write_data(open(fn) { |f| f.read})
        end
      end
    end

    def restore_jobs(jobs_dir, job_metadata, options)
      current_jobs = @client.job.list_all
      job_metadata[:names].each do |job|
        if current_jobs.include?(job) && !options[:overwrite_jobs]
          puts "#{job} already exists, skipping..."
        else
          xml = File.read("#{jobs_dir}/#{job}.xml")
          if options[:overwrite_jobs]
            puts "Removing existing #{job} and creating..."
            @client.job.delete(job)
          else
            puts "Creating job: #{job}..."
          end
          @client.job.create(job, xml)
        end
      end
    end

    def restore_views(views_dir, view_metadata, options)
      current_views = @client.view.list
      view_metadata[:details].each do |view|
        next if view[:view_name] == "All"
        if current_views.include?(view[:view_name]) && !options[:overwrite_views]
          puts "#{view[:view_name]} already exists.. skipping creation..."
        else
          if options[:overwrite_views]
            puts "Removing existing #{view[:view_name]} and creating..."
            @client.view.delete(view[:view_name])
          else
            puts "Creating view: #{view[:view_name]}..."
          end
          @client.view.create_list_view(:name => view[:view_name])
          view[:job_names].each do |job|
            puts "Adding #{job} to #{view[:view_name]} view..."
            @client.view.add_job(view[:view_name], job)
          end
        end
      end
    end

  end
end

