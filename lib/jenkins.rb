
require 'jenkins/backup'
require 'jenkins/configuration'

module Jenkins
  extend Configuration
  class << self

    def new(params = {})
      Jenkins::Backup.new(params)
    end

    def method_missing(method, *args, &block)
      return super unless new.respond_to?(method)
      new.send(method, *args, &block)
    end

    def respond_to?(method, include_private = false)
      new.respond_to?(method, include_private) || super(method, include_private)
    end
  end
end
