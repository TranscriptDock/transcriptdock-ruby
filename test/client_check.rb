require_relative '../lib/transcriptdock'

def check(value, message)
  raise message unless value
end

def raises(type)
  begin
    yield
  rescue type => error
    return error
  end
  raise "Expected #{type}"
end

base = ENV.fetch('TRANSCRIPTDOCK_TEST_BASE_URL')
client = TranscriptDock::Client.new('td_live_fixture_only', base_url: base)
body = {'source' => {'url' => 'https://example.com/video'}, 'mode' => 'captions_only', 'max_credits' => 1}
2.times do
  out = client.create_job(body, idempotency_key: 'fixture-replay-01')
  check(out['future_field'] == 42, 'future response field lost')
  check(out['request']['body'] == body, 'request body changed')
  check(out['request']['idempotency_key'] == 'fixture-replay-01' && out['request']['authorized'], 'headers changed')
end
out = client.request('GET', '/v1/jobs', query: {cursor: 'a/b?c&d', limit: 7})
check(out['request']['query']['cursor'] == ['a/b?c&d'], 'cursor encoding changed')
check(client.get_job('id/other?x')['request']['path'].end_with?('id%2Fother%3Fx'), 'ID path encoding changed')
check(client.get_transcript('fixture')['words'][0]['start_ms'] == 123, 'timing unit changed')
check(client.export_transcript('fixture', format: 'srt').include?('fixture'), 'export lost')
%w[succeeded failed cancelled].each { |s| check(client.wait_for_job(s)['status'] == s, 'terminal status lost') }
err = raises(TranscriptDock::JobTimeoutError) { client.wait_for_job('processing', timeout: 0.15, poll_interval: 1) }
check(err.job['status'] == 'processing', 'timeout lost last job')
err = raises(TranscriptDock::ApiError) { client.request('GET', '/v1/rate-limit') }
check(err.status == 429 && err.retryable && err.retry_after_seconds == 4 && err.request_id == 'fixture-request', 'API error fields lost')
check(!err.message.include?('td_live_fixture_only'), 'key in error')
check(raises(TranscriptDock::ApiError) { client.request('GET', '/v1/redirect') }.status == 302, 'redirect followed')
%w[gateway error-shape malformed array].each { |p| raises(TranscriptDock::ApiError) { client.request('GET', "/v1/#{p}") } }
%w[/v1/batches /v1/video-discoveries /v1/language-discoveries].each do |path|
  raises(ArgumentError) { client.request('POST', path, body: {}) }
  check(client.request('POST', path, body: {fixture: true}, idempotency_key: 'fixture-generic-01')['request']['method'] == 'POST', 'generic submission failed')
end
check(client.request('DELETE', '/v1/transcripts/fixture')['request']['method'] == 'DELETE', 'delete dispatch failed')
['http://example.com', 'https://user:pass@example.com', 'https://example.com/path', 'https://example.com?x=1'].each do |url|
  raises(ArgumentError) { TranscriptDock::Client.new('fixture-key', base_url: url) }
end
raises(ArgumentError) { TranscriptDock::Client.new("bad\nkey") }
raises(ArgumentError) { client.create_job({}, idempotency_key: "bad\nreplay") }
raises(ArgumentError) { client.request('GET', '/v1/../secret') }
raises(ArgumentError) { client.wait_for_job('fixture', timeout: Float::NAN) }
check(raises(TranscriptDock::ApiError) { client.request('GET', '/v1/slow', timeout: 0.03) }.code == 'NETWORK_ERROR', 'transport timeout not handled')
raises(ArgumentError) { client.request('post', '/v1/jobs', body: {}) }
raises(ArgumentError) { client.request('GET', '/v1/%2e%2e/secret') }
{'budget' => [402, 'BUDGET_EXCEEDED'], 'conflict' => [409, 'IDEMPOTENCY_CONFLICT'], 'jobs/not-owned' => [404, 'NOT_FOUND']}.each do |path, expected|
  err = raises(TranscriptDock::ApiError) { client.request('GET', "/v1/#{path}") }
  check([err.status, err.code] == expected && !err.retryable, 'budget, replay conflict or inaccessible job error lost')
end

puts 'Ruby client checks passed'
