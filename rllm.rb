#!/usr/bin/env ruby

require 'rubygems'
require 'rugged'
require 'optparse'
require 'uri'
require 'net/http'
require 'json'
require 'fileutils'

require 'openai'
require 'net/ssh'

require_relative './lib/merge_iteration'
require_relative './lib/fixup_iteration'

# Configuration
# CUDA_VISIBLE_DEVICES="0,1" ~/tmp/llama.cpp/build-rpc-cuda/bin/llama-server -m ~/models/Llama-3.1-Nemotron-70B-Instruct-HF-IQ4_XS.gguf -ngl 99 -b 4096 -ub 1024 -c 80000 -t 8 --host 0.0.0.0 --port 8081 -ctk q4_0 -ctv q4_0 -fa

LLAMA_API_ENDPOINT = 'http://localhost:8081'
LOG_FILE = 'rllm.log'

options = {}

repo_dir = '/home/snajpa/linux'
#src_commit = '0bc21e701a6f' # os-wip
#cherrypick_commit_range = 'ed9ef699255e..0ed74379442a' # os-wip
src_commit = '0bc21e701a6f' # 6.13-rc5+
cherrypick_commit_range = '319addc2ad90..68eb45c3ef9e'
#src_commit = '8155b4ef3466' # next-20240104
#cherrypick_commit_range = 'd3e69f8ab5df..c0dcbf44ec68' # from 6.12.7
dst_branch_name = 'vpsadminos-devel'
dst_remote_name = 'origin'

OpenAI.configure do |config|
  config.access_token = ""
  config.log_errors = true
  config.uri_base = LLAMA_API_ENDPOINT
  config.request_timeout = 900
end

OptionParser.new do |opts|
  opts.banner = "Usage: rllm.rb [options]"
end.parse!

repo = Rugged::Repository.new(repo_dir)

llmc = OpenAI::Client.new

range = cherrypick_commit_range.split('..')
walker = Rugged::Walker.new(repo)
walker.push(repo.lookup(range[1]).oid)
walker.hide(repo.lookup(range[0]).oid)
commit_list = walker.map(&:oid).reverse

def force_push(repo_dir, dst_remote_name, dst_branch_name)
  `cd #{repo_dir} && git push -f #{dst_remote_name} #{dst_branch_name}`
  $?
end
# take optional block of code to run on incoming lines
def run_ssh_commands(ssh_host, ssh_user, ssh_options, quiet, commands, &block)
  begin
    puts "Connecting to #{ssh_host} as #{ssh_user}" unless quiet
    Net::SSH.start(ssh_host, ssh_user, ssh_options) do |ssh|
      commands.each do |command|
        puts "Executing: #{command[:cmd]}" unless quiet
        command[:output_lines] = []
        command[:exit_status] = nil
        ch = ssh.open_channel do |ch|
          ch.request_pty do |ch, success|
            raise "Failed to get PTY" unless success

            ch.exec(command[:cmd]) do |ch, success|
              raise "Failed to execute command" unless success

              ch.on_data do |_, data|
                data.split("\n").each do |line|
                  print "\r" + line.gsub(/\r\n?/, "") unless quiet
                  command[:output_lines] << line
                  block.call(ch, command, line) if block
                end
              end

              ch.on_extended_data do |_, _, data|
                data.split("\n").each do |line|
                  unless quiet
                    print "\r" + line.gsub(/\r\n?/, "")
                  end
                  command[:output_lines] << line
                  block.call(ch, command, line) if block
                end
              end

              ch.on_request("exit-status") do |_, data|
                command[:exit_status] = data.read_long
                unless quiet
                  tty_width = `tput cols`.to_i
                  print "\r" + "Exit status: #{command[:exit_status]}" + " " * (tty_width - 15) + "\n"
                  puts
                end
                if command[:exit_status] != 0 && !command[:can_fail]
                  ch.close
                  raise
                end
              end
            end
          end
        end
        ch.wait
      end
    end
 # rescue Interrupt
 #   return { failed: true, results: commands }
  rescue => e
    puts e.message
    puts e.backtrace unless quiet
    return { failed: true, results: commands }
  end
  { failed: false, results: commands }
end

def ssh_build_iteration(ssh_host, ssh_user, ssh_options, quiet, dst_remote_name, dst_branch_name, dir, cores, &block)
  commands = [
    { cmd: "cd #{dir}; git fetch", can_fail: false },
    { cmd: "cd #{dir}; git checkout -f master", can_fail: false },
    { cmd: "cd #{dir}; git branch -D #{dst_branch_name}", can_fail: true },
    { cmd: "cd #{dir}; git reset --hard #{dst_remote_name}/#{dst_branch_name}", can_fail: true },
    { cmd: "cd #{dir}; git checkout --progress -b #{dst_branch_name} #{dst_remote_name}/#{dst_branch_name}", can_fail: false },
    { cmd: "cd #{dir}; make -j #{cores}", can_fail: true }
  ]
  run_ssh_commands("172.16.106.12", "root", ssh_options, quiet, commands, &block)
end

puts "Starting merge process"
puts "Source commit: #{src_commit}"
puts "Cherrypick commit range: #{cherrypick_commit_range}"
puts "Destination branch: #{dst_branch_name}"
puts "Destination remote: #{dst_remote_name}"
puts "Repository: #{repo_dir}"

prev_results = {}
error_context = ""
compiled_ok = false
until compiled_ok
  # Load previous results and check if they are valid
  if File.exist?('merge_results.bin') && prev_results.empty?
    f = File.open('merge_results.bin', 'r')
    prev_results = Marshal.load(f.read)
    f.close
    File.delete('merge_results.bin')
    puts "Loaded previous merge results"
  else
    prev_results = merge_iteration(llmc, 0.8, repo, src_commit, commit_list, dst_branch_name, error_context, prev_results)
    puts "Saving merge results"
    f = File.open('merge_results.bin', 'w')
    f.write(Marshal.dump(prev_results))
    f.close
  end

  f = force_push(repo_dir, dst_remote_name, dst_branch_name)
  exit unless f.exitstatus == 0

  quiet = false
  ssh_options = {
    # verbose: :debug,
    use_agent: true,
    config: true,
    verify_host_key: :never
  }

  # First we do a parallel fast build
  b = ssh_build_iteration("172.16.106.12", "root", ssh_options, quiet,
                          dst_remote_name, dst_branch_name, "~/linux-rllm", 64) do |ch, command, line|
    if line =~ /error:/i
      puts "Error detected, closing connection"
      command[:exit_status] = 1
      ch.close
      raise
    end
  end

  compiled_ok = b[:results].last[:exit_status] == 0
  break if compiled_ok

  b = ssh_build_iteration("172.16.106.12", "root", ssh_options, quiet,
                          dst_remote_name, dst_branch_name, "~/linux-rllm", 64)

  error_context_lines = []
  was_error = false
  b[:results].last[:output_lines].each do |line|
    if line =~ /error:/i
      was_error = true
    end
    if was_error
      error_context_lines << line
    end
  end
  error_context = error_context_lines.join("\n")

  puts "Compiled OK: #{compiled_ok}"

  # If build failed, we're going to let the LLM to try to fix it
  # First we need to identify all files that have had any compile issues such as errors or warnings
  # Then we need to identify the lines that have had issues
  # Then we need to identify which patch is most likely the cause of the issue
  # Then we gather context around the lines that have had issues
  # Then we send this information to the LLM along with the full patch to fix the issue by telling us which file it would like to change
  # Then we provide the LLM with more context from the file around the lines that have had issues
  # The we let the LLM provide any number of codeblocks prepended with FILE_PATH: `file/path` to indicate the new location of the block
  # Then we apply the changes and try to compile again
  # If the compilation fails again, we repeat the process 3 times and then let's do a new round of merge
  # 

  if !compiled_ok && error_context.length > 0
    # Attempt automated fixes
    puts "Build failed, attempting automated fixes..."
    compiled_ok = attempt_llm_fix(llmc, error_context, repo, prev_results[:porting_steps])
    
    if !compiled_ok
      puts "Automated fixes failed after 3 attempts, continuing with next merge iteration"
    end
  end
end