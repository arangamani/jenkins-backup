
require 'jenkins/configuration'
require 'jenkins_api_client'
require 'tmpdir'
require 'libarchive'

module Jenkins
  class Backup
    attr_accessor *Configuration::VALID_PARAMS

    def initialize(params = {})
      params = Jenkins.params.merge(params)
      Configuration::VALID_PARAMS.each do |key|
        send("#{key}=", params[key])
      end
    end

    def backup(options = {})
      puts "Creating a backup of Jenkins Configuration from #{server_ip}"
      metadata = {:jobs => {}}
      client = JenkinsApi::Client.new(
        :server_ip => server_ip,
        :username => username,
        :password => password
      )

      tmp_dir = Dir.mktmpdir
      puts "Temp Dir: #{tmp_dir}"
      # Jobs
      jobs_dir = "#{tmp_dir}/jobs"
      Dir.mkdir(jobs_dir)
      jobs = client.job.list_all
      metadata[:jobs][:count] = jobs.length
      metadata[:jobs][:names] = jobs

      jobs.each do |job|
        puts "Obtaining xml for #{job}"
        xml = client.job.get_config(job)
        File.open("#{jobs_dir}/#{job}.xml", "w") { |f| f.write(xml) }
      end
      File.open("#{tmp_dir}/metadata.json", "w") { |f| f.write(metadata.to_json) }

      Archive.write_open_filename("jenkins.tar.gz", Archive::COMPRESSION_GZIP, Archive::FORMAT_TAR) do |ar|
        Dir.glob("#{jobs_dir}/*xml").each do |fn|
          short_name = fn.split("#{tmp_dir}/").last
          ar.new_entry do |entry|
            entry.copy_stat(fn)
            entry.pathname = short_name
            ar.write_header(entry)
            ar.write_data(open(fn) { |f| f.read})
          end
        end
        metadata_fn = "#{tmp_dir}/metadata.json"
        ar.new_entry do |entry|
          entry.copy_stat(metadata_fn)
          entry.pathname = "metadata.json"
          ar.write_header(entry)
          ar.write_data(open(metadata_fn) { |f| f.read})
        end
      end
      puts metadata.inspect
    end

    def restore(options = {})
      puts "Restoring backup to Jenkins"
    end

  end
end

