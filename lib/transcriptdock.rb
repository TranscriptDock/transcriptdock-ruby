# frozen_string_literal: true
require 'net/http'
require 'json'
require 'uri'
require 'ipaddr'

module TranscriptDock
  VERSION = '0.1.0'

  class ApiError < StandardError
    attr_reader :code, :status, :retryable, :request_id, :retry_after_seconds
    def initialize(code, message, status: nil, retryable: false, request_id: nil, retry_after_seconds: nil)
      super(message)
      @code, @status, @retryable = code, status, retryable
      @request_id, @retry_after_seconds = request_id, retry_after_seconds
    end
  end

  class JobTimeoutError < StandardError
    attr_reader :job
    def initialize(job)
      super('The job is still running. Check it again using its ID.')
      @job = job
    end
  end

  class Client
    def initialize(api_key, base_url: 'https://www.transcriptdock.com', timeout: 30)
      raise ArgumentError, 'Provide an API key without whitespace or control characters.' unless api_key.is_a?(String) && api_key.match?(/\A[!-~]+\z/)
      origin = URI.parse(base_url)
      begin
        loopback = origin.hostname == 'localhost' || IPAddr.new(origin.hostname).loopback?
      rescue IPAddr::InvalidAddressError, ArgumentError
        loopback = false
      end
      unless origin.is_a?(URI::HTTP) && origin.hostname && (origin.scheme == 'https' || (origin.scheme == 'http' && loopback)) && origin.userinfo.nil? && origin.query.nil? && origin.fragment.nil? && ['', '/'].include?(origin.path)
        raise ArgumentError, 'Use an HTTPS origin, or loopback HTTP, without credentials, path, query or fragment.'
      end
      @api_key, @base_url = api_key, base_url.sub(%r{/\z}, '')
      @timeout = positive(timeout, 'timeout')
    rescue URI::InvalidURIError
      raise ArgumentError, 'Provide a valid API origin.'
    end

    def request(method, path, body: nil, query: {}, idempotency_key: nil, text: false, timeout: @timeout)
      raise ArgumentError, 'Provide a supported HTTP method.' unless method.is_a?(String) && %w[GET POST PUT PATCH DELETE HEAD OPTIONS].include?(method.upcase)
      method = method.upcase
      unless path.is_a?(String) && path.start_with?('/v1/') && !path.match?(/[?#\\]/) && !URI::DEFAULT_PARSER.unescape(path).split('/').any? { |s| ['.', '..'].include?(s) }
        raise ArgumentError, 'Use a /v1/ path and pass query parameters separately.'
      end
      needs_key = method == 'POST' && (%w[/v1/jobs /v1/batches /v1/video-discoveries /v1/language-discoveries].include?(path) || path.end_with?('/retry'))
      if needs_key || !idempotency_key.nil?
        raise ArgumentError, 'Idempotency keys need 8 to 128 printable ASCII characters.' unless idempotency_key.is_a?(String) && idempotency_key.match?(/\A[ -~]{8,128}\z/)
      end
      uri = URI.parse(@base_url + path)
      uri.query = URI.encode_www_form(query.reject { |_, v| v.nil? }) unless query.empty?
      headers = {'Authorization' => "Bearer #{@api_key}", 'Accept' => 'application/json', 'User-Agent' => "transcriptdock-ruby/#{VERSION}"}
      headers['Idempotency-Key'] = idempotency_key if idempotency_key
      headers['Content-Type'] = 'application/json' unless body.nil?
      req = Net::HTTPGenericRequest.new(method, !body.nil?, method != 'HEAD', uri.request_uri, headers)
      req.body = JSON.generate(body) unless body.nil?
      http = Net::HTTP.new(uri.hostname, uri.port, nil)
      http.use_ssl = uri.scheme == 'https'
      http.max_retries = 0
      http.open_timeout = http.read_timeout = http.write_timeout = positive(timeout, 'timeout')
      begin
        response = http.start { |connection| connection.request(req) }
      rescue IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError
        raise ApiError.new('NETWORK_ERROR', 'Could not reach the API. Check the job before retrying a submission.', retryable: true), cause: nil
      end
      status = response.code.to_i
      if status < 200 || status >= 300
        begin
          envelope = JSON.parse(response.body)
        rescue JSON::ParserError
          envelope = {}
        end
        envelope = {} unless envelope.is_a?(Hash)
        error = envelope['error'].is_a?(Hash) ? envelope['error'] : {}
        raise ApiError.new(redact(error['code'] || 'HTTP_ERROR'), redact(error['message'] || "Request failed with status #{status}."), status: status,
          retryable: error.fetch('retryable', status == 429 || status >= 500), request_id: envelope['request_id'] && redact(envelope['request_id']), retry_after_seconds: error['retry_after_seconds'])
      end
      return response.body if text
      begin
        result = JSON.parse(response.body)
      rescue JSON::ParserError
        raise ApiError.new('INVALID_RESPONSE', 'The API did not return JSON.'), cause: nil
      end
      raise ApiError.new('INVALID_RESPONSE', 'The API did not return a JSON object.') unless result.is_a?(Hash)
      result
    end

    def capabilities = request('GET', '/v1/capabilities')
    def create_job(body, idempotency_key:) = request('POST', '/v1/jobs', body: body, idempotency_key: idempotency_key)
    def get_job(id) = request('GET', "/v1/jobs/#{encode_id(id)}")
    def get_transcript(id) = request('GET', "/v1/transcripts/#{encode_id(id)}")
    def export_transcript(id, format: 'txt')
      raise ArgumentError, 'Choose json, txt, srt or vtt.' unless %w[json txt srt vtt].include?(format)
      request('GET', "/v1/transcripts/#{encode_id(id)}/export", query: {format: format}, text: true)
    end

    def wait_for_job(id, timeout: 120, poll_interval: 3)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + positive(timeout, 'timeout')
      positive(poll_interval, 'poll_interval')
      last = nil
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise JobTimeoutError, last if remaining <= 0
        last = request('GET', "/v1/jobs/#{encode_id(id)}", timeout: [remaining, @timeout].min)
        return last if %w[succeeded failed cancelled].include?(last['status'])
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise JobTimeoutError, last if remaining <= 0
        sleep [remaining, poll_interval].min
      end
    end

    private
    def positive(value, name)
      raise ArgumentError, "#{name} must be a finite positive number." unless value.is_a?(Numeric) && value.finite? && value > 0
      value
    end
    def encode_id(id)
      raise ArgumentError, 'Provide a nonempty ID.' unless id.is_a?(String) && !id.empty? && !['.', '..'].include?(id)
      URI.encode_www_form_component(id).gsub('+', '%20')
    end
    def redact(value)
      value.to_s.gsub(@api_key, '[REDACTED]').gsub(/td_live_[A-Za-z0-9_-]+|Bearer\s+\S+/i, '[REDACTED]')
    end
  end
end
