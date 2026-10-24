#!/usr/bin/ruby
# feature-routing.rb: route a PR's changed files to the review features of its repo.
#
# Usage:
#   feature-routing.rb route --repo <name> [source] [--candidates] < changed-files
#   feature-routing.rb validate --repo <name> [source]
#   source: --root <dir> | --git <checkout> --ref <ref> | --gh <owner/repo> --ref <ref>
#
# Reads <repo>/features.yaml, the rule files it names, and lenses.yaml from the
# source's features tree (skills/pr-review/features, the edge-dev-agents copy of
# ~/.cursor/skills/pr-review/features). The schema is documented in that tree's
# README.md. Routing is deterministic: changed paths (one per line on stdin, as
# `gh pr diff --name-only` prints them) are matched against each feature's
# `paths` globs with File.fnmatch, no model call.
#
# --git and --gh read committed content at --ref (the caller passes a base
# branch, never the PR head), so a PR cannot change the rules applied to it.
# --root reads a plain directory; it exists for tests and offline checks.
#
# route prints one JSON manifest on stdout:
#   {repo, source, configFound, changedFiles,
#    features: [{name, status, owners, lenses, rules, matchedFiles}],
#    shadow:   [{name, matchedFiles}]   (candidates matched but not loaded),
#    rules:    [{id, feature, rule, severity, scope, sources}],
#    lenses:   [{name, always?, focus?, features?}]}
# and one summary line on stderr. Active features load; candidates load only
# with --candidates (and are listed in `shadow` otherwise); retired never load.
# `lenses` always starts with correctness. A repo with no features.yaml is not
# an error: configFound is false and the manifest is the correctness-only one.
#
# validate checks the repo's features.yaml, lenses.yaml and every rule file it
# names, and prints "OK <counts>". lenses.yaml is read only when features.yaml
# exists.
#
# Exit: 0 ok; 1 schema or source error (message on stderr); 2 usage error.
require 'yaml'
require 'json'
require 'open3'
require 'base64'

FEATURES_DIR = 'skills/pr-review/features'.freeze
CURSOR_PREFIX = '.cursor'.freeze # where FEATURES_DIR sits in an edge-dev-agents checkout
FNM = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH
STATUSES = %w[candidate active retired].freeze
SEVERITIES = %w[critical warning suggestion].freeze
FEATURE_KEYS = %w[name paths owners lenses rules status].freeze
RULE_KEYS = %w[id rule scope severity enabled sources].freeze
LENS_KEYS = %w[name focus].freeze
ID_RE = /\A[a-z0-9][a-z0-9-]*\z/.freeze

class SchemaError < StandardError; end

def usage(message)
  warn "feature-routing: #{message}"
  warn 'usage: feature-routing.rb (route|validate) --repo <name> (--root <dir> | --git <checkout> --ref <ref> | --gh <owner/repo> --ref <ref>) [--candidates]'
  exit 2
end

# --- sources: each returns the file's text, or nil when it does not exist ---

class DirSource
  def initialize(root)
    @root = root
  end

  def label
    "dir:#{@root}"
  end

  def read(rel)
    path = File.join(@root, rel)
    File.file?(path) ? File.read(path) : nil
  end
end

class GitSource
  def initialize(checkout, ref)
    @checkout = checkout
    @ref = ref
  end

  def label
    "git:#{@checkout}@#{@ref}"
  end

  def read(rel)
    out, err, st = Open3.capture3('git', '-C', @checkout, 'show', "#{@ref}:#{CURSOR_PREFIX}/#{FEATURES_DIR}/#{rel}")
    return out if st.success?
    return nil if err =~ /does not exist|exists on disk, but not in/
    raise SchemaError, "git show #{@ref}:#{rel} failed: #{err.strip}"
  end
end

class GhSource
  def initialize(slug, ref)
    @slug = slug
    @ref = ref
  end

  def label
    "gh:#{@slug}@#{@ref}"
  end

  def read(rel)
    path = "repos/#{@slug}/contents/#{CURSOR_PREFIX}/#{FEATURES_DIR}/#{rel}?ref=#{@ref}"
    out, err, st = Open3.capture3('gh', 'api', path, '--jq', '.content')
    return Base64.decode64(out) if st.success?
    return nil if err =~ /HTTP 404/
    raise SchemaError, "gh api #{path} failed: #{err.strip}"
  end
end

# --- schema ---

def parse_yaml(text, rel)
  YAML.safe_load(text, filename: rel)
rescue Psych::Exception => e
  raise SchemaError, "#{rel}: #{e.message}"
end

def string_list(value, where, allow_empty: false)
  ok = value.is_a?(Array) && value.all? { |v| v.is_a?(String) && !v.strip.empty? }
  raise SchemaError, "#{where} must be a list of non-empty strings" unless ok
  raise SchemaError, "#{where} must not be empty" if value.empty? && !allow_empty
  value
end

def check_keys(hash, allowed, where)
  extra = hash.keys - allowed
  raise SchemaError, "#{where}: unknown key(s) #{extra.join(', ')} (allowed: #{allowed.join(', ')})" unless extra.empty?
end

def load_lenses(source)
  text = source.read('lenses.yaml') or raise SchemaError, 'lenses.yaml not found in the features tree'
  doc = parse_yaml(text, 'lenses.yaml')
  list = doc.is_a?(Hash) ? doc['lenses'] : nil
  raise SchemaError, 'lenses.yaml: top level must be {lenses: [...]}' unless list.is_a?(Array)
  lenses = {}
  list.each_with_index do |l, i|
    where = "lenses.yaml lenses[#{i}]"
    raise SchemaError, "#{where} must be a mapping" unless l.is_a?(Hash)
    check_keys(l, LENS_KEYS, where)
    name, focus = l['name'], l['focus']
    raise SchemaError, "#{where}.name must match #{ID_RE.source}" unless name.is_a?(String) && name =~ ID_RE
    raise SchemaError, "#{where}: correctness always runs and is not declared" if name == 'correctness'
    raise SchemaError, "#{where}.focus must be a non-empty string" unless focus.is_a?(String) && !focus.strip.empty?
    raise SchemaError, "lenses.yaml: duplicate lens #{name}" if lenses.key?(name)
    lenses[name] = focus.strip
  end
  lenses
end

def load_rules(source, repo, feature)
  rel = "#{repo}/#{feature['rules']}"
  text = source.read(rel) or raise SchemaError, "#{rel} (rules of feature #{feature['name']}) not found"
  doc = parse_yaml(text, rel)
  list = doc.is_a?(Hash) ? doc['rules'] : nil
  raise SchemaError, "#{rel}: top level must be {rules: [...]}" unless list.is_a?(Array)
  list.each_with_index.map do |r, i|
    where = "#{rel} rules[#{i}]"
    raise SchemaError, "#{where} must be a mapping" unless r.is_a?(Hash)
    check_keys(r, RULE_KEYS, where)
    raise SchemaError, "#{where}.id must match #{ID_RE.source}" unless r['id'].is_a?(String) && r['id'] =~ ID_RE
    raise SchemaError, "#{where}.rule must be a non-empty string" unless r['rule'].is_a?(String) && !r['rule'].strip.empty?
    raise SchemaError, "#{where}.severity must be one of #{SEVERITIES.join(', ')}" unless SEVERITIES.include?(r['severity'])
    enabled = r.key?('enabled') ? r['enabled'] : true
    raise SchemaError, "#{where}.enabled must be true or false" unless [true, false].include?(enabled)
    scope = r.key?('scope') ? string_list(r['scope'], "#{where}.scope") : feature['paths']
    sources = r.key?('sources') ? string_list(r['sources'], "#{where}.sources") : []
    { 'id' => r['id'], 'feature' => feature['name'], 'rule' => r['rule'].strip, 'severity' => r['severity'],
      'enabled' => enabled, 'scope' => scope, 'sources' => sources }
  end
end

# -> [features, lenses], or nil when the repo has no features.yaml. lenses.yaml
# is read only once a features.yaml exists, so a ref that predates the features
# tree routes to correctness only.
def load_features(source, repo)
  rel = "#{repo}/features.yaml"
  text = source.read(rel)
  return nil if text.nil?
  lenses = load_lenses(source)
  doc = parse_yaml(text, rel)
  list = doc.is_a?(Hash) ? doc['features'] : nil
  raise SchemaError, "#{rel}: top level must be {features: [...]}" unless list.is_a?(Array)
  names = {}
  features = list.each_with_index.map do |f, i|
    where = "#{rel} features[#{i}]"
    raise SchemaError, "#{where} must be a mapping" unless f.is_a?(Hash)
    check_keys(f, FEATURE_KEYS, where)
    name = f['name']
    raise SchemaError, "#{where}.name must be a non-empty string" unless name.is_a?(String) && !name.strip.empty?
    raise SchemaError, "#{rel}: duplicate feature #{name}" if names.key?(name)
    names[name] = true
    paths = string_list(f['paths'], "#{where}.paths")
    raise SchemaError, "#{where}.paths needs at least one pattern that is not a ! exclusion" if paths.all? { |p| p.start_with?('!') }
    owners = f.key?('owners') ? string_list(f['owners'], "#{where}.owners", allow_empty: true) : []
    flens = f.key?('lenses') ? string_list(f['lenses'], "#{where}.lenses", allow_empty: true) : []
    unknown = flens - lenses.keys - ['correctness']
    raise SchemaError, "#{where}.lenses: unknown lens(es) #{unknown.join(', ')} (lenses.yaml has: #{lenses.keys.join(', ')})" unless unknown.empty?
    raise SchemaError, "#{where}.status must be one of #{STATUSES.join(', ')}" unless STATUSES.include?(f['status'])
    if f.key?('rules') && !(f['rules'].is_a?(String) && f['rules'] =~ %r{\A[\w.-]+\.ya?ml\z})
      raise SchemaError, "#{where}.rules must be a file name in the repo's features directory (*.yaml)"
    end
    feature = { 'name' => name, 'paths' => paths, 'owners' => owners, 'lenses' => flens - ['correctness'],
                'status' => f['status'], 'rules' => f['rules'] }
    feature['ruleRecords'] = f['rules'] ? load_rules(source, repo, feature) : []
    feature
  end
  check_rule_ids(features, rel)
  [features, lenses]
end

def check_rule_ids(features, rel)
  seen = {}
  features.each do |f|
    f['ruleRecords'].each do |r|
      raise SchemaError, "#{rel}: rule id #{r['id']} is declared by both #{seen[r['id']]} and #{f['name']}" if seen.key?(r['id'])
      seen[r['id']] = f['name']
    end
  end
end

# --- routing ---

# `dir/**` means everything under dir, as in .gitignore; fnmatch needs `dir/**/*`.
def normalize_glob(glob)
  return '**/*' if glob == '**'
  glob.end_with?('/**') ? "#{glob}/*" : glob
end

def matches?(globs, path)
  include = globs.reject { |g| g.start_with?('!') }
  exclude = globs.select { |g| g.start_with?('!') }.map { |g| g[1..-1] }
  include.any? { |g| File.fnmatch(normalize_glob(g), path, FNM) } &&
    exclude.none? { |g| File.fnmatch(normalize_glob(g), path, FNM) }
end

def route(features, lenses, files, candidates)
  loaded, shadow = [], []
  (features || []).each do |f|
    next if f['status'] == 'retired'
    hit = files.select { |p| matches?(f['paths'], p) }
    next if hit.empty?
    if f['status'] == 'candidate' && !candidates
      shadow << { 'name' => f['name'], 'matchedFiles' => hit }
      next
    end
    loaded << f.merge('matchedFiles' => hit)
  end
  rules = loaded.flat_map do |f|
    f['ruleRecords'].select { |r| r['enabled'] && files.any? { |p| matches?(r['scope'], p) } }
                    .map { |r| r.reject { |k, _| k == 'enabled' } }
  end
  spawned = []
  loaded.each { |f| f['lenses'].each { |l| spawned << l unless spawned.include?(l) } }
  lens_out = [{ 'name' => 'correctness', 'always' => true }] + spawned.map do |l|
    { 'name' => l, 'focus' => lenses[l], 'features' => loaded.select { |f| f['lenses'].include?(l) }.map { |f| f['name'] } }
  end
  [loaded.map { |f| f.reject { |k, _| %w[ruleRecords paths].include?(k) } }, shadow, rules, lens_out]
end

# --- CLI ---

cmd = ARGV.shift
usage('missing subcommand') unless %w[route validate].include?(cmd)
opts = { candidates: false }
until ARGV.empty?
  arg = ARGV.shift
  case arg
  when '--repo', '--root', '--git', '--gh', '--ref'
    value = ARGV.shift or usage("#{arg} needs a value")
    opts[arg[2..-1].to_sym] = value
  when '--candidates' then opts[:candidates] = true
  else usage("unknown argument #{arg}")
  end
end
usage('--repo is required') unless opts[:repo]
usage('--repo must be a bare repo name') unless opts[:repo] =~ /\A[\w.-]+\z/
picked = %i[root git gh].select { |k| opts[k] }
usage('pass exactly one of --root, --git, --gh') unless picked.length == 1
usage("--#{picked[0]} needs --ref") if %i[git gh].include?(picked[0]) && !opts[:ref]
source = case picked[0]
         when :root then DirSource.new(opts[:root])
         when :git then GitSource.new(opts[:git], opts[:ref])
         else GhSource.new(opts[:gh], opts[:ref])
         end

begin
  features, lenses = load_features(source, opts[:repo])
  if cmd == 'validate'
    raise SchemaError, "#{opts[:repo]}/features.yaml not found" if features.nil?
    rule_count = features.sum { |f| f['ruleRecords'].length }
    puts "OK #{opts[:repo]}: #{features.length} features, #{rule_count} rules, #{lenses.length} lenses"
    exit 0
  end
  files = STDIN.read.split("\n").map(&:strip).reject(&:empty?).uniq
  loaded, shadow, rules, lens_out = route(features, lenses, files, opts[:candidates])
  puts JSON.pretty_generate(
    'repo' => opts[:repo], 'source' => source.label, 'configFound' => !features.nil?,
    'changedFiles' => files.length, 'features' => loaded, 'shadow' => shadow, 'rules' => rules, 'lenses' => lens_out
  )
  warn "feature-routing: #{opts[:repo]} via #{source.label}: " +
       (features.nil? ? 'no features.yaml, correctness only' :
        "#{loaded.length} feature(s) [#{loaded.map { |f| f['name'] }.join(', ')}], #{rules.length} rule(s), " \
        "lenses [#{lens_out.map { |l| l['name'] }.join(', ')}], #{shadow.length} shadow")
rescue SchemaError => e
  warn "feature-routing: #{e.message}"
  exit 1
end
