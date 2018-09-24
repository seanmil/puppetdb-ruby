require 'httparty'
require 'logger'

module PuppetDB
  class APIError < RuntimeError
    attr_reader :code, :response
    def initialize(response)
      @response = response
    end
  end

  class AccessDenied < APIError
  end

  class Forbidden < AccessDenied
  end

  class Unauthorized < AccessDenied
  end

  class FixSSLConnectionAdapter < HTTParty::ConnectionAdapter
    def attach_ssl_certificates(http, options)
      http.cert    = OpenSSL::X509::Certificate.new(File.read(options[:pem]['cert'])) unless options[:pem]['cert'].nil?
      http.key     = OpenSSL::PKey::RSA.new(File.read(options[:pem]['key'])) unless options[:pem]['cert'].nil?
      http.ca_file = options[:pem]['ca_file']
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    end
  end

  class Client
    include HTTParty
    attr_reader :use_ssl
    attr_reader :token
    attr_writer :logger

    def hash_get(hash, key)
      untouched = hash[key]
      return untouched if untouched

      sym = hash[key.to_sym]
      return sym if sym

      str = hash[key.to_s]
      return str if str

      nil
    end

    def hash_includes?(hash, *sought_keys)
      sought_keys.each { |x| return false unless hash.include?(x) }
      true
    end

    def debug(msg)
      @logger.debug(msg) if @logger
    end

    def initialize(settings, query_api_version = 4, command_api_version = 1)
      @query_api_version = query_api_version
      @command_api_version = command_api_version

      server = hash_get(settings, 'server')
      pem    = hash_get(settings, 'pem')
      token  = hash_get(settings, 'token')

      scheme = URI.parse(server).scheme

      unless %w[http https].include? scheme
        error_msg = 'Configuration error: :server must specify a protocol of either http or https'
        raise error_msg
      end

      @use_ssl = scheme == 'https'
      if @use_ssl && pem
        unless hash_includes?(pem, 'ca_file')
          error_msg = 'Configuration error: https:// specified but pem is missing or incomplete. It requires cert, key, and ca_file.'
          raise error_msg
        end
        unless token || hash_includes?(pem, 'key', 'cert')
          error_msg = 'Configuration error: https:// specified but missing RBAC token or full pem specification (requires cert and key)'
          raise error_msg
        end

        self.class.default_options = { pem: pem }
        self.class.connection_adapter(FixSSLConnectionAdapter)
        self.class.headers('X-Authentication' => token) if token
      end

      self.class.base_uri(server)
    end

    def raise_if_error(response)
      raise Unauthorized, response if response.code == 401
      raise Forbidden, response if response.code == 403
      raise APIError, response if response.code.to_s =~ %r{^[4|5]}
    end

    def request(endpoint, query, opts = {})
      path = "/pdb/query/v#{@query_api_version}"
      if endpoint == ''
        # PQL
        json_query = query
      else
        path += "/#{endpoint}"
        query = PuppetDB::Query.maybe_promote(query)
        json_query = query.build
      end

      filtered_opts = { 'query' => json_query }
      opts.each do |k, v|
        if k == :counts_filter
          filtered_opts['counts-filter'] = JSON.dump(v)
        else
          filtered_opts[k.to_s.sub('_', '-')] = v
        end
      end

      debug("#{path} #{json_query} #{opts}")

      ret = self.class.get(path, body: filtered_opts)
      raise_if_error(ret)

      total = ret.headers['X-Records']
      total = ret.parsed_response.length if total.nil?

      Response.new(ret.parsed_response, total)
    end

    def command(command, payload, version)
      path = "/pdb/cmd/v#{@command_api_version}"

      query = {
        'command' => command,
        'version' => version,
        'certname' => payload['certname']
      }

      debug("#{path} #{query} #{payload}")

      ret = self.class.post(
        path,
        query: query,
        body: payload.to_json,
        headers: {
          'Accept'       => 'application/json',
          'Content-Type' => 'application/json'
        }
      )
      raise_if_error(ret)

      Response.new(ret.parsed_response)
    end
  end
end
