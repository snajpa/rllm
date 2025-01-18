#!/usr/bin/env ruby
# frozen_string_literal: true

require 'curses'
require 'tty-tree'
require 'thread'

###############################################################################
# Widgets::Base
###############################################################################
module Widgets
  class Base
    attr_accessor :win, :top, :left, :height, :width

    def initialize
      @top    = 0
      @left   = 0
      @height = 0
      @width  = 0
      @win    = nil
    end

    def resize(_total_rows, _total_cols); end

    def build_window(color_pair_idx = 0)
      @win.close if @win
      @win = Curses::Window.new(@height, @width, @top, @left)
      @win.bkgd(Curses.color_pair(color_pair_idx)) if color_pair_idx > 0
      @win.nodelay = true
    end

    def render; end

    def handle_input(_ch); end

    protected

    # Helper to write text
    def draw_text(y, x, text, color_pair_id = nil)
      @win.setpos(y, x)
      if color_pair_id
        @win.attron(Curses.color_pair(color_pair_id)) { @win.addstr(text) }
      else
        @win.addstr(text)
      end
    end

    # Enhanced draw_box with a color parameter for borders
    def draw_box(left, top, width, height, border_color = 3)
      right  = left + width - 1
      bottom = top + height - 1

      # Draw horizontal lines
      (left..right).each do |xx|
        @win.attron(Curses.color_pair(border_color)) do
          @win.setpos(top, xx);    @win.addch('-')
          @win.setpos(bottom, xx); @win.addch('-')
        end
      end

      # Draw vertical lines
      (top..bottom).each do |yy|
        @win.attron(Curses.color_pair(border_color)) do
          @win.setpos(yy, left);  @win.addch('|')
          @win.setpos(yy, right); @win.addch('|')
        end
      end

      # Draw corners
      @win.attron(Curses.color_pair(border_color)) do
        @win.setpos(top, left);     @win.addch('+')
        @win.setpos(top, right);    @win.addch('+')
        @win.setpos(bottom, left);  @win.addch('+')
        @win.setpos(bottom, right); @win.addch('+')
      end
    end
  end
end

###############################################################################
# Top SubPanes (with Word Wrap + Tail Mode behavior)
###############################################################################
module Widgets
  class TopSubPanes < Base
    attr_accessor :focus_index, :headers, :contents,
                  :scroll_offsets, :active,
                  :tail_modes,    # parallel array for each subpane
                  :word_wrap,
                  :original_tail_modes # store original tail-mode upon focus

    def initialize(num_panes = 3)
      super()
      @headers        = Array.new(num_panes) { |i| "Pane #{i+1}" }
      @contents       = Array.new(num_panes) { ["Default Content"] }
      @scroll_offsets = Array.new(num_panes, 0)
      @tail_modes     = Array.new(num_panes, true)  # tail mode default ON
      @focus_index    = 0
      @active         = false
      @word_wrap      = false

      # We'll store each subpane's "original tail mode" to restore on focus exit
      @original_tail_modes = Array.new(num_panes, false)
    end

    def num_panes
      @headers.size
    end

    def add_pane(header_text, content_lines)
      @headers << header_text
      @contents << content_lines
      @scroll_offsets << 0
      @tail_modes << true
      @original_tail_modes << false
      auto_scroll_to_bottom(num_panes - 1)  # if tail mode is on by default
    end

    def remove_pane(index)
      return if index < 0 || index >= num_panes
      @headers.delete_at(index)
      @contents.delete_at(index)
      @scroll_offsets.delete_at(index)
      @tail_modes.delete_at(index)
      @original_tail_modes.delete_at(index)
      # Adjust focus_index
      @focus_index = [@focus_index, num_panes - 1].min
      @focus_index = 0 if num_panes <= 0
    end

    #
    # Called when we do :update_top_pane => we replace content and possibly scroll
    #
    def update_pane(index, header: nil, lines: nil)
      return if index < 0 || index >= num_panes
      @headers[index] = header if header
      if lines
        @contents[index] = Array(lines)
        # If tail mode is enabled, auto-scroll to last lines
        auto_scroll_to_bottom(index) if @tail_modes[index]
      end
    end

    #
    # Enable or disable tail mode for a single subpane
    #
    def set_tail_mode(index, enabled)
      return if index < 0 || index >= num_panes
      @tail_modes[index] = !!enabled
    end

    #
    # Called by the UI when we focus a subpane => store current tail_mode as "original"
    #
    def set_original_tail_mode(i, val)
      return unless i >= 0 && i < num_panes
      @original_tail_modes[i] = val
    end

    #
    # Called by the UI when we lose focus => restore the original tail mode
    #
    def restore_original_tail_mode(i)
      return unless i >= 0 && i < num_panes
      @tail_modes[i] = @original_tail_modes[i]
    end

    def resize(total_rows, total_cols)
      @height = total_rows / 3
      @width  = total_cols
      @top    = 0
      @left   = 0
      build_window(0)
    end

    def render
      @win.clear

      if num_panes == 0
        @win.refresh
        return
      end

      pane_width = @width / num_panes

      num_panes.times do |i|
        sub_left  = i * pane_width
        # Last pane might get leftover columns
        sub_width = (i == num_panes - 1) ? (@width - (pane_width * (num_panes - 1))) : pane_width

        # If this subpane is the actively focused one, highlight border
        border_color = (@active && i == @focus_index) ? 6 : 3
        draw_box(sub_left, 0, sub_width, @height, border_color)

        # Header
        header_str = @headers[i]
        header_y   = 1
        center_x   = sub_left + (sub_width - header_str.size) / 2

        # If active, highlight the header text; else use color 5
        header_color = (@active && i == @focus_index) ? 2 : 5
        draw_text(header_y, center_x, header_str, header_color)

        # scrollable text area
        interior_height = @height - 2
        text_area_height= interior_height - 1
        text_start_y    = 2

        draw_subpane_text(i, sub_left, text_start_y, sub_width, text_area_height)
      end

      @win.refresh
    end

    #
    # Handle user input for the active subpane. 
    # We only disable tail mode once the user scrolls manually.
    # If user presses End => jump to bottom, re-enable tail if the original was true.
    #
    def handle_input(ch)
      return unless @active

      idx = @focus_index
      case ch
      when Curses::KEY_HOME
        # Jump to top
        @scroll_offsets[idx] = 0
        # If we had tail mode on, user is now manually scrolling => turn it off
        @tail_modes[idx] = false if @tail_modes[idx]

      when Curses::KEY_END
        # Jump to bottom
        auto_scroll_to_bottom(idx)
        # If original tail mode was true => turn it back on
        if @original_tail_modes[idx]
          @tail_modes[idx] = true
        end

      when Curses::KEY_UP
        single_line_up(idx)
        @tail_modes[idx] = false if @tail_modes[idx]

      when Curses::KEY_DOWN
        single_line_down(idx)
        @tail_modes[idx] = false if @tail_modes[idx]

      when Curses::KEY_PPAGE
        page_up(idx)
        @tail_modes[idx] = false if @tail_modes[idx]

      when Curses::KEY_NPAGE
        page_down(idx)
        @tail_modes[idx] = false if @tail_modes[idx]
      end
    end

    private

    #
    # -- WORD WRAP CHANGES --
    # Split each "raw line" into multiple lines if it exceeds max_width,
    # but try to break on word boundaries.
    #
    def wrap_line(line, max_width)
      return [line] if line.length <= max_width || max_width < 1

      words = line.split(/(\s+)/)  # keep whitespace tokens so we can rebuild
      wrapped = []
      current = ""

      words.each do |w|
        # If adding this word would exceed max_width, push current and reset
        if (current + w).length > max_width
          wrapped << current.rstrip unless current.empty?
          current = w.lstrip
        else
          current += w
        end
      end
      wrapped << current.rstrip unless current.empty?

      wrapped
    end

    # Return the entire wrapped content for subpane i
    def wrapped_content_for_pane(i, max_width)
      return @contents[i] unless @word_wrap

      all_wrapped = []
      @contents[i].each do |raw_line|
        all_wrapped.concat(wrap_line(raw_line, max_width))
      end
      all_wrapped
    end

    #
    # Auto-scroll subpane i so the "latest lines" are visible
    # (like a "tail" of a log).
    #
    def auto_scroll_to_bottom(i)
      subpane_width = @width / num_panes
      # If it's the last pane, we might have leftover width
      if i == (num_panes - 1)
        subpane_width = @width - (subpane_width * (num_panes - 1))
      end

      max_width       = subpane_width - 2
      lines_wrapped   = wrapped_content_for_pane(i, max_width)
      displayable     = [@height - 3, 1].max
      needed_offset   = lines_wrapped.size - displayable
      @scroll_offsets[i] = needed_offset < 0 ? 0 : needed_offset
    end

    def draw_subpane_text(idx, sub_left, text_start_y, sub_width, text_area_height)
      max_width       = sub_width - 2
      lines_wrapped   = wrapped_content_for_pane(idx, max_width)
      scroll_off      = @scroll_offsets[idx]

      # clamp scroll offset in case wrapping changed line count
      if scroll_off > lines_wrapped.size - 1
        scroll_off = lines_wrapped.size - 1
        scroll_off = 0 if scroll_off < 0
        @scroll_offsets[idx] = scroll_off
      end

      visible_end = scroll_off + text_area_height - 1

      line_y = text_start_y
      (scroll_off..visible_end).each do |line_idx|
        break if line_idx >= lines_wrapped.size

        line_str = lines_wrapped[line_idx]
        x_offset = sub_left + 1
        truncated = line_str[0, max_width]

        @win.setpos(line_y, x_offset)
        @win.attron(Curses.color_pair(3)) do
          @win.addstr(truncated)
        end

        line_y += 1
        break if line_y >= text_start_y + text_area_height
      end
    end

    def page_up(i)
      page_size = @height - 3
      @scroll_offsets[i] = [@scroll_offsets[i] - page_size, 0].max
    end

    def page_down(i)
      page_size       = @height - 3
      subpane_width   = @width / num_panes
      subpane_width   = @width - (subpane_width * (num_panes - 1)) if i == (num_panes - 1)
      max_width       = subpane_width - 2
      lines_wrapped   = wrapped_content_for_pane(i, max_width)
      max_offset      = [lines_wrapped.size - page_size, 0].max
      @scroll_offsets[i] = [@scroll_offsets[i] + page_size, max_offset].min
    end

    def single_line_up(i)
      @scroll_offsets[i] = [@scroll_offsets[i] - 1, 0].max
    end

    def single_line_down(i)
      page_size       = @height - 3
      subpane_width   = @width / num_panes
      subpane_width   = @width - (subpane_width * (num_panes - 1)) if i == (num_panes - 1)
      max_width       = subpane_width - 2
      lines_wrapped   = wrapped_content_for_pane(i, max_width)
      max_offset      = [lines_wrapped.size - page_size, 0].max
      @scroll_offsets[i] = [@scroll_offsets[i] + 1, max_offset].min
    end
  end
end

###############################################################################
# Tree Widget (middle pane)
###############################################################################
module Widgets
  class TreePane < Base
    attr_accessor :tree, :selected_index, :active

    def initialize(tty_tree_data = {})
      super()
      @tree           = TTY::Tree.new(tty_tree_data)
      @selected_index = 0
      @active         = false
    end

    def resize(total_rows, total_cols)
      @height = total_rows / 3
      @width  = total_cols
      @top    = total_rows / 3
      @left   = 0
      build_window(3)
    end

    def render
      @win.clear

      border_color = @active ? 6 : 3
      draw_box(0, 0, @width, @height, border_color)

      lines = @tree.render.lines

      lines.each_with_index do |line, idx|
        line_color = 4 # default tree node color
        line_color = 2 if (@active && idx == @selected_index) # highlight selected
        draw_text(idx + 1, 2, line.chomp, line_color)
      end

      @win.refresh
    end

    def handle_input(ch)
      return unless @active
      lines = @tree.render.lines
      case ch
      when Curses::KEY_UP
        @selected_index = [@selected_index - 1, 0].max
      when Curses::KEY_DOWN
        @selected_index = [@selected_index + 1, lines.size - 1].min
      end
    end

    def reset_selection
      @selected_index = 0
    end
  end
end

###############################################################################
# Bottom Pane (scrollable, word wrap, tail-mode logic)
###############################################################################
module Widgets
  class ContentPane < Base
    attr_accessor :lines, :scroll_offset, :active,
                  :auto_update_enabled, :tail_mode,
                  :word_wrap

    # We'll store the "original" tail mode from the moment we gain focus
    attr_accessor :original_tail_mode

    def initialize
      super()
      @lines               = ["Bottom default line"]
      @scroll_offset       = 0
      @active              = false
      @auto_update_enabled = true  # If false, we won't overwrite from tree
      @tail_mode           = true  # Tail mode on by default
      @word_wrap           = false

      @original_tail_mode  = false
    end

    def resize(total_rows, total_cols)
      top_height    = total_rows / 3
      mid_height    = total_rows / 3
      @height = total_rows - top_height - mid_height - 1
      @width  = total_cols
      @top    = top_height + mid_height
      @left   = 0
      build_window(3)
    end

    def render
      @win.clear

      border_color = @active ? 6 : 3
      draw_box(0, 0, @width, @height, border_color)

      # If tail_mode is still on, we auto-scroll to bottom
      scroll_if_tail_mode

      interior_height = @height - 2
      visible_end     = @scroll_offset + interior_height - 1

      max_w      = @width - 2
      wrapped    = all_wrapped_lines(max_w)

      # clamp scroll offset if wrapping changed line count
      if @scroll_offset > wrapped.size - 1
        @scroll_offset = [wrapped.size - 1, 0].max
      end

      line_y = 1
      ( @scroll_offset..visible_end ).each do |line_idx|
        break if line_idx >= wrapped.size
        truncated = wrapped[line_idx][0, max_w]
        draw_text(line_y, 1, truncated, 3)
        line_y += 1
      end

      @win.refresh
    end

    #
    # This method receives keyboard events only if @active is true.
    #
    def handle_input(ch)
      return unless @active

      case ch
      when Curses::KEY_HOME
        # Jump to top
        @scroll_offset = 0
        # If tail mode was on, user scrolled => turn it off
        @tail_mode = false if @tail_mode

      when Curses::KEY_END
        # Jump to bottom
        scroll_to_bottom
        # If original tail mode was true => re-enable
        @tail_mode = true if @original_tail_mode

      when Curses::KEY_UP
        single_line_up
        @tail_mode = false if @tail_mode

      when Curses::KEY_DOWN
        single_line_down
        @tail_mode = false if @tail_mode

      when Curses::KEY_PPAGE
        page_up
        @tail_mode = false if @tail_mode

      when Curses::KEY_NPAGE
        page_down
        @tail_mode = false if @tail_mode
      end

      $stderr.puts "DEBUG BOTTOM KEY => #{ch.inspect}"
    end

    #
    # Replaces lines. We'll scroll to bottom if tail_mode is on in render.
    #
    def set_lines(new_lines)
      @lines = new_lines
    end

    #
    # For the UI to restore tail mode after losing focus
    #
    def restore_original_tail_mode
      @tail_mode = @original_tail_mode
    end

    private

    #
    # Word wrap logic
    #
    def wrap_line(line, max_width)
      return [line] if line.length <= max_width || max_width < 1

      words = line.split(/(\s+)/)
      wrapped = []
      current = ""

      words.each do |w|
        if (current + w).length > max_width
          wrapped << current.rstrip unless current.empty?
          current = w.lstrip
        else
          current += w
        end
      end
      wrapped << current.rstrip unless current.empty?
      wrapped
    end

    def all_wrapped_lines(max_width)
      return @lines unless @word_wrap

      result = []
      @lines.each do |raw_line|
        result.concat(wrap_line(raw_line, max_width))
      end
      result
    end

    def scroll_to_bottom
      max_w        = @width - 2
      wrapped      = all_wrapped_lines(max_w)
      displayable  = [@height - 2, 1].max
      needed_offset = wrapped.size - displayable
      needed_offset = 0 if needed_offset < 0
      @scroll_offset = needed_offset
    end

    def scroll_if_tail_mode
      return unless @tail_mode
      scroll_to_bottom
    end

    def page_up
      page_size    = @height - 2
      @scroll_offset = [@scroll_offset - page_size, 0].max
    end

    def page_down
      page_size    = @height - 2
      max_w        = @width - 2
      wrapped      = all_wrapped_lines(max_w)
      max_offset   = [wrapped.size - page_size, 0].max
      @scroll_offset = [@scroll_offset + page_size, max_offset].min
    end

    def single_line_up
      @scroll_offset = [@scroll_offset - 1, 0].max
    end

    def single_line_down
      page_size   = @height - 2
      max_w       = @width - 2
      wrapped     = all_wrapped_lines(max_w)
      max_offset  = [wrapped.size - page_size, 0].max
      @scroll_offset = [@scroll_offset + 1, max_offset].min
    end
  end
end

###############################################################################
# Status Bar
###############################################################################
module Widgets
  class StatusBar < Base
    attr_accessor :message

    def initialize
      super()
      @message = "Press 'q' to exit | Tab to cycle focus"
    end

    def resize(total_rows, total_cols)
      @height = 1
      @width  = total_cols
      @top    = total_rows - 1
      @left   = 0
      build_window(1)
    end

    def render
      @win.clear
      draw_text(0, 0, @message, 1)
      @win.refresh
    end
  end
end

###############################################################################
# NcursesUI: Manages the loop, focusing, event queue, etc.
###############################################################################
class NcursesUI
  attr_reader :event_queue

  # With 3 subpanes, we have focus states:
  #   0 -> subpane0
  #   1 -> subpane1
  #   2 -> subpane2
  #   3 -> tree
  #   4 -> bottom
  def initialize(top_panes:, tree_pane:, content_pane:, status_bar:, node_lookup:)
    @top_panes    = top_panes
    @tree_pane    = tree_pane
    @content_pane = content_pane
    @status_bar   = status_bar

    # node_lookup => node_name => { :ui_content => [...], :children => {}, ... }
    @node_lookup  = node_lookup

    # Start focusing on the tree pane
    @focus_state  = @top_panes.num_panes # e.g. 3
    @prev_focus_state = nil
    @running      = false
    @event_queue  = Queue.new
  end

  def start
    @ui_thread = Thread.new { run_curses_loop }
    @running = true
  end

  def join
    @ui_thread&.join
  end

  def post_event(event)
    @event_queue << event
  end

  def stop
    @running = false
  end

  #
  # Helpers for building TTY::Tree, node lookup
  #
  def self.meta_to_tty_tree(meta_tree)
    result = {}
    meta_tree.each do |node_name, node_val|
      child_hash = node_val[:children] || {}
      result[node_name] = meta_to_tty_tree(child_hash)
    end
    result
  end

  def self.build_node_lookup(meta_tree, lookup = {})
    meta_tree.each do |node_name, node_val|
      lookup[node_name] = node_val
      child_hash = node_val[:children] || {}
      build_node_lookup(child_hash, lookup)
    end
    lookup
  end

  private

  def run_curses_loop
    setup_curses

    begin
      Curses.timeout = 50
      while @running
        ch = Curses.getch
        handle_user_input(ch) if ch

        handle_queued_events
        resize_widgets
        render_widgets

        sleep(0.05)
      end
    ensure
      Curses.close_screen
    end
  end

  def setup_curses
    Curses.init_screen
    Curses.start_color
    Curses.curs_set(0)
    Curses.noecho
    Curses.stdscr.keypad(true)

    # We define 6 color pairs:
    # 1) Status bar (white on blue)
    # 2) Highlight text (black on white)
    # 3) Default (white on black)
    # 4) Tree node lines (yellow on black)
    # 5) Subpane header normal (cyan on black)
    # 6) Active border (red on black)
    Curses.init_pair(1, Curses::COLOR_WHITE, Curses::COLOR_BLUE)
    Curses.init_pair(2, Curses::COLOR_BLACK, Curses::COLOR_WHITE)
    Curses.init_pair(3, Curses::COLOR_WHITE, Curses::COLOR_BLACK)
    Curses.init_pair(4, Curses::COLOR_YELLOW, Curses::COLOR_BLACK)
    Curses.init_pair(5, Curses::COLOR_CYAN, Curses::COLOR_BLACK)
    Curses.init_pair(6, Curses::COLOR_RED, Curses::COLOR_BLACK)
  end

  def resize_widgets
    rows = Curses.lines
    cols = Curses.cols

    @top_panes.resize(rows, cols)
    @tree_pane.resize(rows, cols)
    @content_pane.resize(rows, cols)
    @status_bar.resize(rows, cols)

    # Detect if focus changed from the previously-focused pane
    if @focus_state != @prev_focus_state
      pane_lost_focus(@prev_focus_state)   unless @prev_focus_state.nil?
      pane_gained_focus(@focus_state)      unless @focus_state.nil?
      @prev_focus_state = @focus_state
    end

    # If focus_state < number_of_subpanes, top is active
    if @focus_state < @top_panes.num_panes
      @top_panes.active      = true
      @top_panes.focus_index = @focus_state
    else
      @top_panes.active      = false
    end

    tree_state   = @top_panes.num_panes  # => 3
    bottom_state = tree_state + 1        # => 4

    @tree_pane.active        = (@focus_state == tree_state)
    @content_pane.active     = (@focus_state == bottom_state)
  end

  #
  # Focus logic:
  #
  # - 'pane_gained_focus' => store the pane's "original" tail mode
  #   (but do NOT forcibly disable anything)
  # - 'pane_lost_focus'   => restore tail mode to original
  #
  def pane_gained_focus(state)
    return if state.nil?
    if state < @top_panes.num_panes
      i = state
      original = @top_panes.tail_modes[i]
      @top_panes.set_original_tail_mode(i, original)
    elsif state == @top_panes.num_panes
      # tree pane => no tail mode logic
    else
      # bottom pane
      @content_pane.original_tail_mode = @content_pane.tail_mode
    end
  end

  def pane_lost_focus(state)
    return if state.nil?
    if state < @top_panes.num_panes
      i = state
      @top_panes.restore_original_tail_mode(i)
    elsif state == @top_panes.num_panes
      # tree pane => nothing
    else
      # bottom
      @content_pane.restore_original_tail_mode
    end
  end

  def render_widgets
    @top_panes.render
    @tree_pane.render

    # If auto_update is enabled, set bottom content from the tree
    if @content_pane.auto_update_enabled
      set_bottom_content_from_tree
    end

    @content_pane.render
    @status_bar.render
  end

  def set_bottom_content_from_tree
    lines = @tree_pane.tree.render.lines
    sidx  = [[@tree_pane.selected_index, 0].max, lines.size - 1].min
    raw_line  = lines[sidx].to_s.strip
    node_name = raw_line.gsub(/^[\s├└─│]+/, '')

    data = @node_lookup[node_name]
    if data && data[:ui_content].is_a?(Array)
      @content_pane.set_lines(data[:ui_content])
    else
      @content_pane.set_lines(["No content for '#{node_name}'"])
    end
  end

  def handle_queued_events
    until @event_queue.empty?
      event = @event_queue.pop(true) rescue nil
      next unless event

      case event
      when :stop
        stop
      when Hash
        handle_hash_event(event)
      end
    end
  end

  def reload_tree(new_meta_tree_data)
    @tty_tree_data = self.class.meta_to_tty_tree(new_meta_tree_data)
    @node_lookup   = self.class.build_node_lookup(new_meta_tree_data)
    @tree_pane.tree = TTY::Tree.new(@tty_tree_data)
  end

  #
  # This is where you handle updates from the main thread
  #
  def handle_hash_event(event)
    case event[:cmd]
    when :update_status
      # { cmd: :update_status, message: "New text" }
      @status_bar.message = event[:message].to_s

    when :update_tree
      # { cmd: :update_tree, meta_tree_data: ... }
      new_meta_tree = event[:meta_tree_data]
      reload_tree(new_meta_tree)

    when :update_bottom_content
      # { cmd: :update_bottom_content, lines: [...], override_auto: bool }
      lines = event[:lines] || []
      @content_pane.set_lines(lines)
      if event.key?(:override_auto)
        @content_pane.auto_update_enabled = !event[:override_auto] ? true : false
      end

    when :update_top_pane
      # { cmd: :update_top_pane, index: 1, header: "New Header", ui_content: [...] }
      i = event[:index].to_i
      hdr = event[:header]
      if i < @top_panes.num_panes
        @top_panes.update_pane(i, header: hdr, lines: event[:ui_content])
      end

    when :add_top_pane
      # { cmd: :add_top_pane, header: "XYZ", ui_content: [...] }
      hdr  = event[:header]    || "Pane #{@top_panes.num_panes+1}"
      cnt  = event[:ui_content]|| ["(empty)"]
      @top_panes.add_pane(hdr, cnt)

    when :remove_top_pane
      # { cmd: :remove_top_pane, index: 1 }
      i = event[:index].to_i
      @top_panes.remove_pane(i)

    when :disable_bottom_auto_update
      @content_pane.auto_update_enabled = false

    when :enable_bottom_auto_update
      @content_pane.auto_update_enabled = true

    when :enable_tail_mode_top
      i = event[:index].to_i
      @top_panes.set_tail_mode(i, true)

    when :disable_tail_mode_top
      i = event[:index].to_i
      @top_panes.set_tail_mode(i, false)

    when :enable_tail_mode_bottom
      @content_pane.tail_mode = true

    when :disable_tail_mode_bottom
      @content_pane.tail_mode = false
    end
  end

  #
  # Focus switching logic
  #
  def handle_user_input(ch)
    case ch
    when 'q'
      stop
    # Tab can be ASCII 9, "\t" or KEY_BTAB
    when 9, "\t", Curses::KEY_BTAB
      max_focus = @top_panes.num_panes + 1
      @focus_state = (@focus_state + 1) % (max_focus + 1)

    else
      # Let the active widget handle input
      @top_panes.handle_input(ch)
      @tree_pane.handle_input(ch)
      @content_pane.handle_input(ch)
    end
  end
end

###############################################################################
# Demo Usage
###############################################################################
if __FILE__ == $PROGRAM_NAME
  # A sample meta-tree
  meta_tree_data = {
    "Root" => {
      :ui_content => [""],
      :children => {
        "Child A" => {
          :ui_content => ["Child A - line1"],
          :children=> {}
        },
        "Child B" => {
          :ui_content => ["Child B - line1", "Child B - line2"],
          :children=> {}
        }
      }
    }
  }

  # Add lines to show wrapping, etc.
  15.times do |i|
    meta_tree_data["Root"][:ui_content] << "Root line #{i} with a bunch of extra words to demonstrate word wrapping"
  end

  # Build TTY::Tree data & node lookup
  tty_tree_data = NcursesUI.meta_to_tty_tree(meta_tree_data)
  node_lookup   = NcursesUI.build_node_lookup(meta_tree_data)

  # Create widgets
  top_panes    = Widgets::TopSubPanes.new(3)
  tree_pane    = Widgets::TreePane.new(tty_tree_data)
  content_pane = Widgets::ContentPane.new
  status_bar   = Widgets::StatusBar.new

  # Optional: enable word wrap for demonstration
  top_panes.word_wrap    = true
  content_pane.word_wrap = true

  # Create the UI
  ui = NcursesUI.new(
    top_panes:    top_panes,
    tree_pane:    tree_pane,
    content_pane: content_pane,
    status_bar:   status_bar,
    node_lookup:  node_lookup
  )

  ui.start

  lines_for_pane0 = 120.times.map { |i| "Line #{i} for Pane" }
  more_lines_for_pane0 = lines_for_pane0 + ["New line A", "New line B"]
  ui.post_event(cmd: :update_top_pane, index: 0, header: "Still Pane #1", ui_content: more_lines_for_pane0)
  ui.post_event(cmd: :update_top_pane, index: 1, header: "Still Pane #2", ui_content: more_lines_for_pane0)

  # Some demonstration updates
  sleep(3)
  ui.post_event(cmd: :update_status, message: "Status changed from main... press Home/End in a subpane")

  # Wait, then stop
  sleep(10)
  ui.post_event(:stop)
  ui.join
  puts "Main thread: UI has shut down."
end
