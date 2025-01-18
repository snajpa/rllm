def run_ssh_commands(ui, ssh_host, ssh_user, ssh_options, quiet, commands, &block)
  begin
    logme "Connecting to #{ssh_host} as #{ssh_user}" unless quiet
    Net::SSH.start(ssh_host, ssh_user, ssh_options) do |ssh|
      commands.each do |command|
        logme "Executing: #{command[:cmd]}" unless quiet
        command[:output_lines] = []
        command[:exit_status] = nil
        ch = ssh.open_channel do |ch|
          ch.request_pty do |ch, success|
            raise "Failed to get PTY" unless success

            ch.exec(command[:cmd]) do |ch, success|
              raise "Failed to execute command" unless success

              ch.on_data do |_, data|
                data.split("\n").each do |line|
                  logme line unless quiet
                  command[:output_lines] << line
                  block.call(ch, command, line) if block
                end
              end

              ch.on_extended_data do |_, _, data|
                data.split("\n").each do |line|
                  unless quiet
                    logme line unless quiet
                  end
                  command[:output_lines] << line
                  block.call(ch, command, line) if block
                end
              end

              ch.on_request("exit-status") do |_, data|
                command[:exit_status] = data.read_long
                unless quiet
                  tty_width = `tput cols`.to_i
                  logme "Exit status: #{command[:exit_status]}" + " " * (tty_width - 15) + "\n"
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
    logme e.message
    logme e.backtrace unless quiet
    return { failed: true, results: commands }
  end
  { failed: false, results: commands }
end
