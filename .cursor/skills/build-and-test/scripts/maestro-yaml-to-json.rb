#!/usr/bin/ruby
# maestro-yaml-to-json.rb [--env K=V ...] (<flow.yaml> | --steps <inline yaml>)
#
# Converts a Maestro flow to the JSON the XCUITest interpreter runs. The runner
# never parses YAML: this script does, on the host, with the system Ruby's
# Psych (no install needed).
#
# Output: {"file": <abs path>, "config": <header>, "commands": [...]}, plus
# a top-level "env" object from the --env K=V arguments (Maestro's `-e`).
# Every `env:` map becomes a list of [key, value] pairs so the runner
# evaluates entries in file order (a later entry may read an earlier one).
# Every `runFlow` that references a file is inlined as `"_flow"` inside its
# args (the same shape, recursively), so the runner gets one self-contained
# document. A runFlow path that needs run-time interpolation (`${...}`) cannot
# be resolved here: the script exits 1 naming the flow and the path.
require 'yaml'
require 'json'

def fail_with(message)
  warn "maestro-yaml-to-json: #{message}"
  exit 1
end

def load_flow(path, stack)
  path = File.expand_path(path)
  fail_with("flow not found: #{path}") unless File.file?(path)
  fail_with("runFlow cycle: #{(stack + [path]).join(' -> ')}") if stack.include?(path)
  build_flow(File.read(path), path, File.dirname(path), stack)
end

# Inline steps from --steps: a command list, one `command: args` map (each
# pair is a command, in order), or a bare command name. runFlow paths resolve
# against the current directory.
def load_steps(text)
  doc = begin
    YAML.safe_load(text)
  rescue Psych::SyntaxError => e
    fail_with("YAML error in --steps: #{e.message}")
  end
  commands =
    case doc
    when nil then []
    when Array then doc
    when Hash then doc.map { |name, args| args.nil? ? name : { name => args } }
    when String then [doc]
    else fail_with("--steps: expected a command list, a command map or a command name")
    end
  build_flow(YAML.dump(commands), '<steps>', Dir.pwd, [])
end

def build_flow(text, path, dir, stack)
  docs = begin
    YAML.load_stream(text)
  rescue Psych::SyntaxError => e
    fail_with("YAML error in #{path}: #{e.message}")
  end
  docs = docs.compact
  config, commands =
    case docs.length
    when 1 then docs[0].is_a?(Array) ? [{}, docs[0]] : fail_with("#{path}: expected a command list")
    when 2 then docs
    else fail_with("#{path}: expected a config document and a command list, found #{docs.length} documents")
    end
  fail_with("#{path}: config is not a map") unless config.is_a?(Hash)
  fail_with("#{path}: commands are not a list") unless commands.is_a?(Array)
  config = config.merge('env' => env_pairs(config['env'], path)) if config.key?('env')

  {
    'file' => path,
    'config' => config,
    'commands' => commands.map { |c| inline_command(c, dir, path, stack + [path]) }
  }
end

# Walks one command, inlining runFlow file references and recursing into the
# nested command lists of runFlow, repeat and retry.
def inline_command(command, dir, path, stack)
  return command unless command.is_a?(Hash) && command.length == 1

  name, args = command.first
  case name
  when 'runFlow', 'retry'
    args = { 'file' => args } if args.is_a?(String)
    return command unless args.is_a?(Hash)

    args = args.dup
    args['env'] = env_pairs(args['env'], path) if args.key?('env')
    if args['file']
      file = args['file'].to_s
      fail_with("#{path}: #{name} file '#{file}' needs run-time interpolation, which the host converter cannot resolve") if file.include?('${')
      args['_flow'] = load_flow(File.expand_path(file, dir), stack)
    end
    args['commands'] = args['commands'].map { |c| inline_command(c, dir, path, stack) } if args['commands'].is_a?(Array)
    { name => args }
  when 'repeat'
    return command unless args.is_a?(Hash) && args['commands'].is_a?(Array)

    { name => args.merge('commands' => args['commands'].map { |c| inline_command(c, dir, path, stack) }) }
  else
    command
  end
end

def env_pairs(env, path)
  fail_with("#{path}: env is not a map") unless env.is_a?(Hash)
  env.map { |key, value| [key.to_s, value.is_a?(String) ? value : value.to_s] }
end

usage = 'usage: maestro-yaml-to-json.rb [--env KEY=VALUE ...] (<flow.yaml> | --steps <inline yaml>)'
cli_env = {}
steps = nil
args = ARGV.dup
while %w[--env --steps].include?(args.first)
  if args.shift == '--steps'
    steps = args.shift.to_s
    next
  end
  pair = args.shift.to_s
  fail_with("--env expects KEY=VALUE, got '#{pair}'") unless pair.include?('=')
  key, value = pair.split('=', 2)
  cli_env[key] = value
end
fail_with(usage) unless args.length == (steps ? 0 : 1)
flow = steps ? load_steps(steps) : load_flow(args[0], [])
puts JSON.generate(flow.merge('env' => cli_env))
