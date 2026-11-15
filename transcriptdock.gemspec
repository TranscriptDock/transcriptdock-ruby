require_relative 'lib/transcriptdock'
Gem::Specification.new do |s|
  s.name = 'transcriptdock'
  s.version = TranscriptDock::VERSION
  s.summary = 'Ruby client for the Transcript Dock transcription API'
  s.description = 'Standard library client for timed transcripts, jobs and the public Transcript Dock API.'
  s.authors = ['Transcript Dock']
  s.email = 'transcriptdock@volods.com'
  s.homepage = 'https://www.transcriptdock.com/docs'
  s.license = 'MIT'
  s.required_ruby_version = '>= 3.2'
  s.files = Dir['lib/**/*.rb'] + ['README.md', 'LICENSE']
  s.metadata['documentation_uri'] = 'https://www.transcriptdock.com/docs'
  s.metadata['source_code_uri'] = 'https://github.com/TranscriptDock/transcriptdock-ruby'
  s.metadata['bug_tracker_uri'] = 'https://github.com/TranscriptDock/transcriptdock-ruby/issues'
  s.metadata['rubygems_mfa_required'] = 'true'
end
