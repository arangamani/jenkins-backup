
require 'rubygems'
require 'yaml'

module Jenkins
  module Configuration
    VALID_PARAMS = [
      :server_ip,
      :server_port,
      :username,
      :password,
      :password_base64
    ]

    attr_accessor *VALID_PARAMS

    def configure
      yield self
    end

    def params
      params = {}
      VALID_PARAMS.each { |key| params[key] = send(key) }
      params
    end

  end
end
