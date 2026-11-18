# Transcript Dock for Ruby

A synchronous client using Ruby's standard libraries. Requires Ruby 3.2 or
newer. Version 0.1.0 is available on
[RubyGems](https://rubygems.org/gems/transcriptdock).

Install from RubyGems:

```sh
gem install transcriptdock -v 0.1.0
```

```ruby
require 'transcriptdock'
require 'securerandom'

client = TranscriptDock::Client.new(ENV.fetch('TRANSCRIPTDOCK_API_KEY'))
# Generate once per intended operation; save with the returned job ID.
key = SecureRandom.uuid
job = client.create_job(
  {source: {url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'},
   mode: 'captions_only', max_credits: 1},
  idempotency_key: key
)
job = client.wait_for_job(job['id'], timeout: 120)
if job['status'] == 'succeeded'
  puts client.export_transcript(job['result_id'], format: 'srt')
end
```

Creating a job can spend credits. This example requests captions only with a
one credit ceiling. It does not enable AI fallback. Save the operation key and
reuse the exact body and same key to recover a lost response. There are no
automatic retries, including in the underlying HTTP transport.

`capabilities`, `create_job`, `get_job`, `get_transcript`, `export_transcript`
and `wait_for_job` provide the core flow. All public endpoints are available
through `request(method, path, body: nil, query: {}, idempotency_key: nil)`.
Use the exact fields in the [API contract](https://www.transcriptdock.com/docs/openapi.yaml)
for batches, discovery, usage, upload slots and webhook endpoints.
A success with no body (204 No Content, such as deleting a webhook endpoint)
returns an empty hash, or an empty string with `text: true`.

Responses are hashes retaining future fields and original timing units.
Exports return the raw JSON, TXT, SRT or VTT string. Polling returns failed and
cancelled terminal jobs normally; inspect status first. `JobTimeoutError#job`
retains the last observed response. `ApiError` exposes `code`, `status`,
`retryable`, `request_id` and `retry_after_seconds`. Error messages redact bearer
keys and do not expose raw gateway pages.

The default per request timeout is 30 seconds. The constructor accepts
`base_url:` and `timeout:`. Custom origins require HTTPS, except loopback HTTP
for development. Redirects are not followed. Upload signed storage URLs
separately without the API key. Store webhook secrets privately and implement
callback signature checks following the API documentation.

## Check and build

From the application repository root with Ruby and Python 3 installed:

```sh
python3 .ci/check.py
mkdir -p dist
gem build transcriptdock.gemspec --output dist/transcriptdock-0.1.0.gem
```

The shared fixture uses loopback HTTP and spends no credits. No lockfile is
needed for third party dependencies because this library has none. Release workflow: https://github.com/TranscriptDock/transcriptdock-ruby/actions.
