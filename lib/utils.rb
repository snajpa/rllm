def get_file_context(repo, path, linenumbers, context_lines = 8)
  file_path = File.join(repo.workdir, path)
  return "" unless File.exist?(file_path)
  return "" if File.directory?(file_path)
  lines = File.read(file_path).split("\n") || []
  return "" if lines.empty?
  context = {}
  linenumbers.each do |linenumber|
    start = [0, linenumber - context_lines].max
    stop = [lines.size - 1, linenumber + context_lines].min
    lines.each_with_index do |line, index|
      if index >= start && index <= stop
        context[start + index] = line
      end
    end
  end
  max_digits = context.keys.max.to_s.length
  context.sort.map { |k, v| "%#{max_digits}d %s" % [k+1, v] }.join("\n")
end
