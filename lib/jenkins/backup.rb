
require 'jenkins/configuration'
require 'jenkins_api_client'
require 'tmpdir'
require 'fileutils'
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

      # General information about backup
      timestamp = Time.now
      metadata[:timestamp] = timestamp
      metadata[:created_by] = username
      metadata[:server_ip] = server_ip
      metadata[:server_port] = server_port || 8080
      metadata[:contents] = "jobs"

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
        metadata_fn = "#{tmp_dir}/metadata.yml"
        ar.new_entry do |entry|
          entry.copy_stat(metadata_fn)
          entry.pathname = "metadata.yml"
          ar.write_header(entry)
          ar.write_data(open(metadata_fn) { |f| f.read})
        end
      end
      FileUtils.rm_rf tmp_dir
      puts metadata.inspect
    end

    def restore(options = {})
      puts "Restoring backup to Jenkins"
    end

  end
end

