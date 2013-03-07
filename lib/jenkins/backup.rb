
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

    def backup(options = {})
      puts "Creating a backup of Jenkins Configuration from #{server_ip}"
      metadata = {:jobs => {}}

      # General information about backup
      timestamp = Time.now
      metadata[:timestamp] = timestamp
      metadata[:created_by] = username
      metadata[:server_ip] = server_ip
      metadata[:server_port] = server_port || 8080
      metadata[:tool_version] = Jenkins::VERSION
      metadata[:contents] = "jobs"

      tmp_dir = Dir.mktmpdir
      puts "Temp Dir: #{tmp_dir}"
      # Jobs
      jobs_dir = "#{tmp_dir}/jobs"
      Dir.mkdir(jobs_dir)
      jobs = @client.job.list_all
      metadata[:jobs][:count] = jobs.length
      metadata[:jobs][:names] = jobs

      jobs.each do |job|
        puts "Obtaining xml for #{job}"
        xml = @client.job.get_config(job)
        File.open("#{jobs_dir}/#{job}.xml", "w") { |f| f.write(xml) }
      end

      views_dir = "#{tmp_dir}/views"
      Dir.mkdir(views_dir)
      views = @client.view.list
      metadata[:views] = {}
      metadata[:views][:count] = views.length
      metadata[:views][:details] = []
      views.each do |view|
        puts "Obtaining xml for #{view}"
        xml = @client.view.get_config(view)
        File.open("#{views_dir}/#{view}.xml", "w") { |f| f.write(xml) }
        metadata[:views][:details] << {
          :view_name => view,
          :job_names => @client.view.list_jobs(view)
        }
      end


      File.open("#{tmp_dir}/metadata.yml", "w") { |f| f.write(metadata.to_yaml) }

      Archive.write_open_filename(
        "jenkins-#{timestamp.to_i}.tar.gz",
        Archive::COMPRESSION_GZIP,
        Archive::FORMAT_TAR
      ) do |ar|
        Dir.glob("#{jobs_dir}/*xml").each do |fn|
          short_name = fn.split("#{tmp_dir}/").last
          ar.new_entry do |entry|
            entry.copy_stat(fn)
            entry.pathname = short_name
            ar.write_header(entry)
            ar.write_data(open(fn) { |f| f.read})
          end
        end
        Dir.glob("#{views_dir}/*xml").each do |fn|
          short_name = fn.split("#{tmp_dir}/").last
          ar.new_entry do |entry|
            entry.copy_stat(fn)
            entry.pathname = short_name
            ar.write_header(entry)
            ar.write_data(open(fn) { |f| f.read})
          end
        end
        metadata_fn = "#{tmp_dir}/metadata.yml"
        ar.new_entry do |entry|
          entry.copy_stat(metadata_fn)
          entry.pathname = "metadata.yml"
          ar.write_header(entry)
          ar.write_data(open(metadata_fn) { |f| f.read})
        end
      end
      FileUtils.rm_rf(tmp_dir)
      puts metadata.inspect
    end

    def restore(name, options = {})

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
      restore_jobs(jobs_dir, metadata[:jobs])

      # Restore views
      restore_views(views_dir, metadata[:views])
      # Get rid of the temp directory
      FileUtils.rm_rf(tmp_dir)
    end

    private

    def restore_jobs(jobs_dir, job_metadata)
      job_metadata[:names].each do |job|
        xml = File.read("#{jobs_dir}/#{job}.xml")
        puts "Creating job: #{job}..."
        @client.job.create(job, xml)
      end
    end

    def restore_views(views_dir, view_metadata)
      view_metadata[:details].each do |view|
        next if view[:view_name] == "All"
        puts "Creating view: #{view[:view_name]}..."
        @client.view.create_list_view(:name => view[:view_name])
        view[:job_names].each do |job|
          puts "Adding #{job} to #{view[:view_name]} view..."
          @client.view.add_job(view[:view_name], job)
        end
      end
    end

  end
end

