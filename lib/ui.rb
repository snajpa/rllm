#!/usr/bin/env ruby
# frozen_string_literal: true

require 'curses'
require 'tty-tree'
require 'thread'

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
# Top SubPanes (supports dynamic add/remove)
###############################################################################
module Widgets
  class TopSubPanes < Base
    attr_accessor :focus_index, :headers, :contents,
                  :scroll_offsets, :active

    def initialize(num_panes = 3)
      super()
      @headers        = Array.new(num_panes) { |i| "Pane #{i+1}" }
      @contents       = Array.new(num_panes) { ["Default Content"] }
      @scroll_offsets = Array.new(num_panes, 0)
      @focus_index    = 0
      @active         = false
    end

    def num_panes
      @headers.size
    end

    def add_pane(header_text, content_lines)
      @headers << header_text
      @contents << content_lines
      @scroll_offsets << 0
    end

    def remove_pane(index)
      return if index < 0 || index >= num_panes
      @headers.delete_at(index)
      @contents.delete_at(index)
      @scroll_offsets.delete_at(index)
      # Adjust focus_index
      @focus_index = [@focus_index, num_panes - 1].min
      @focus_index = 0 if num_panes <= 0
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
        # Last pane might get leftover columns if it doesn't divide evenly
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

    def handle_input(ch)
      return unless @active

      case ch
      when Curses::KEY_PPAGE
        page_up
      when Curses::KEY_NPAGE
        page_down
      end
    end

    private

    def draw_subpane_text(idx, sub_left, text_start_y, sub_width, text_area_height)
      lines       = @contents[idx]
      scroll_off  = @scroll_offsets[idx]
      visible_end = scroll_off + text_area_height - 1

      line_y = text_start_y
      (scroll_off..visible_end).each do |line_idx|
        break if line_idx >= lines.size

        line_str   = lines[line_idx]
        x_offset   = sub_left + 1
        max_length = sub_width - 2
        truncated  = line_str[0, max_length]

        @win.setpos(line_y, x_offset)
        # We'll just use default text color 3
        @win.attron(Curses.color_pair(3)) do
          @win.addstr(truncated)
        end

        line_y += 1
        break if line_y >= text_start_y + text_area_height
      end
    end

    def page_up
      idx = @focus_index
      page_size = @height - 3
      @scroll_offsets[idx] = [@scroll_offsets[idx] - page_size, 0].max
    end

    def page_down
      idx         = @focus_index
      page_size   = @height - 3
      lines_count = @contents[idx].size
      max_offset  = [lines_count - page_size, 0].max
      @scroll_offsets[idx] = [@scroll_offsets[idx] + page_size, max_offset].min
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

      # If active, highlight border, else default
      border_color = @active ? 6 : 3
      draw_box(0, 0, @width, @height, border_color)

      lines = @tree.render.lines

      lines.each_with_index do |line, idx|
        # Non-selected lines get color pair(4) (tree node color)
        line_color = 4
        # If active & selected, highlight with pair(2)
        line_color = 2 if (@active && idx == @selected_index)

        # Write the line
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
# Bottom Pane (scrollable)
###############################################################################
module Widgets
  class ContentPane < Base
    attr_accessor :lines, :scroll_offset, :active, :auto_update_enabled

    def initialize
      super()
      @lines                = ["Bottom default line"]
      @scroll_offset        = 0
      @active               = false
      @auto_update_enabled  = true  # If false, we won't overwrite from tree
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

      # Active border or default
      border_color = @active ? 6 : 3
      draw_box(0, 0, @width, @height, border_color)

      interior_height = @height - 2
      visible_end     = scroll_offset + interior_height - 1

      line_y = 1
      (scroll_offset..visible_end).each do |line_idx|
        break if line_idx >= @lines.size

        truncated = @lines[line_idx][0, @width - 2]
        draw_text(line_y, 1, truncated, 3)
        line_y += 1
      end

      @win.refresh
    end

    def handle_input(ch)
      return unless @active
      case ch
      when Curses::KEY_PPAGE
        page_up
      when Curses::KEY_NPAGE
        page_down
      end
    end

    def set_lines(new_lines)
      @lines = new_lines
      @scroll_offset = new_lines.size
    end

    private

    def page_up
      page_size = @height - 2
      @scroll_offset = [@scroll_offset - page_size, 0].max
    end

    def page_down
      page_size   = @height - 2
      max_offset  = [@lines.size - page_size, 0].max
      @scroll_offset = [@scroll_offset + page_size, max_offset].min
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
      # Always use color_pair(1) for status bar
      draw_text(0, 0, @message, 1)
      @win.refresh
    end
  end
end

###############################################################################
# NcursesUI: Manages the loop & handle_hash_events
###############################################################################
class NcursesUI
  attr_reader :event_queue

  # We'll define the focus states as:
  #   0..(num_subpanes-1) => top subpanes
  #   num_subpanes => tree
  #   num_subpanes+1 => bottom
  #
  def initialize(top_panes:, tree_pane:, content_pane:, status_bar:, node_lookup:)
    @top_panes    = top_panes
    @tree_pane    = tree_pane
    @content_pane = content_pane
    @status_bar   = status_bar

    # node_lookup => node_name => { :ui_content => [...], :children => {}, :other_keys => ... }
    @node_lookup = node_lookup

    @focus_state = 0
    @running     = false
    @event_queue = Queue.new
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

  def self.meta_to_tty_tree(meta_tree)
    # Recursively strip out :ui_content, :other_keys, leaving only the structure
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
    # 1) Status bar  (white on blue)
    # 2) Highlight   (black on white) for selected line or active subpane header
    # 3) Default     (white on black)
    # 4) Tree nodes  (yellow on black for example)
    # 5) Subpane header (cyan on black)
    # 6) Active border (red on black)
    Curses.init_pair(1, Curses::COLOR_WHITE, Curses::COLOR_BLUE)   # Status bar
    Curses.init_pair(2, Curses::COLOR_BLACK, Curses::COLOR_WHITE)  # Highlight text
    Curses.init_pair(3, Curses::COLOR_WHITE, Curses::COLOR_BLACK)  # Default
    Curses.init_pair(4, Curses::COLOR_YELLOW, Curses::COLOR_BLACK) # Tree node lines
    Curses.init_pair(5, Curses::COLOR_CYAN, Curses::COLOR_BLACK)   # Subpane header normal
    Curses.init_pair(6, Curses::COLOR_RED, Curses::COLOR_BLACK)    # Active border
  end

  def resize_widgets
    rows = Curses.lines
    cols = Curses.cols

    @top_panes.resize(rows, cols)
    @tree_pane.resize(rows, cols)
    @content_pane.resize(rows, cols)
    @status_bar.resize(rows, cols)

    if @focus_state < @top_panes.num_panes
      @top_panes.active      = true
      @top_panes.focus_index = @focus_state
    else
      @top_panes.active      = false
    end

    # If top has e.g. 3 subpanes => states 0..2 => tree=3 => bottom=4
    tree_state   = @top_panes.num_panes
    bottom_state = tree_state + 1

    @tree_pane.active        = (@focus_state == tree_state)
    @content_pane.active     = (@focus_state == bottom_state)
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
    @tty_tree_data = NcursesUI::meta_to_tty_tree(new_meta_tree_data)
    @node_lookup  = NcursesUI::build_node_lookup(new_meta_tree_data)
    @tree_pane.tree = TTY::Tree.new(@tty_tree_data)
    #@tree_pane.reset_selection
  end

  #
  # This is where you handle all updates from main
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
      lines  = event[:lines]  || []
      @content_pane.set_lines(lines)
      if event.key?(:override_auto)
        @content_pane.auto_update_enabled = !event[:override_auto] ? true : false
      end

    when :update_top_pane
      # { cmd: :update_top_pane, index: 1, header: "New Header", ui_content: [...] }
      i = event[:index].to_i
      if i < @top_panes.num_panes
        if event[:header]
          @top_panes.headers[i] = event[:header].to_s
        end
        if event[:ui_content]
          @top_panes.contents[i] = Array(event[:ui_content])
        end
      end

    when :add_top_pane
      # { cmd: :add_top_pane, header: "XYZ", ui_content: [...] }
      hdr  = event[:header]  || "Pane #{@top_panes.num_panes+1}"
      cnt  = event[:ui_content] || ["(empty)"]
      @top_panes.add_pane(hdr, Array(cnt))

    when :remove_top_pane
      # { cmd: :remove_top_pane, index: 1 }
      i = event[:index].to_i
      @top_panes.remove_pane(i)

    when :disable_bottom_auto_update
      @content_pane.auto_update_enabled = false

    when :enable_bottom_auto_update
      @content_pane.auto_update_enabled = true
    end
  end

  def handle_user_input(ch)
    case ch
    when 'q'
      stop
      exit
    # Tab can be ASCII 9, "\t" or KEY_BTAB
    when 9, "\t", Curses::KEY_BTAB
      # We have top_panes.num_panes subpane states, then tree, then bottom
      max_focus = @top_panes.num_panes + 1
      @focus_state = (@focus_state + 1) % (max_focus + 1)
    else
      @top_panes.handle_input(ch)
      @tree_pane.handle_input(ch)
      @content_pane.handle_input(ch)
    end
  end
end

###############################################################################
# 3. Demonstration
###############################################################################
if __FILE__ == $PROGRAM_NAME
  # A sample meta-tree
  meta_tree_data = {
    "Root" => {
      :ui_content => ["Root line1", "Root line2"],
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

  # Build TTY::Tree data & node lookup
  tty_tree_data = NcursesUI::meta_to_tty_tree(meta_tree_data)
  node_lookup   = NcursesUI::build_node_lookup(meta_tree_data)

  # Create widgets
  top_panes    = Widgets::TopSubPanes.new(3)
  tree_pane    = Widgets::TreePane.new(tty_tree_data)
  content_pane = Widgets::ContentPane.new
  status_bar   = Widgets::StatusBar.new

  # Create the UI
  ui = NcursesUI.new(
    top_panes:    top_panes,
    tree_pane:    tree_pane,
    content_pane: content_pane,
    status_bar:   status_bar,
    node_lookup:  node_lookup
  )

  ui.start

  # Main thread can do asynchronous work
  # 1) Wait a bit, then update the status
  sleep(3)
  ui.post_event(cmd: :update_status, message: "Status changed from main thread...")

  # 2) Wait, then disable bottom auto-update
  sleep(3)
  ui.post_event(cmd: :disable_bottom_auto_update)
  ui.post_event(cmd: :update_bottom_content, lines: ["Hello from main override!", "2nd line override"], override_auto: true)

  # 3) Add a top pane
  sleep(3)
  ui.post_event(cmd: :add_top_pane, header: "Extra Pane", ui_content: ["Dynamically added top pane"])

  # 4) Remove an existing top pane, e.g. index 1
  sleep(3)
  ui.post_event(cmd: :remove_top_pane, index: 1)

  # 5) Wait, then re-enable auto-update for bottom
  sleep(3)
  ui.post_event(cmd: :enable_bottom_auto_update)

  # 6) Wait, then update the tree by adding "Child C" under "Root"
  sleep(3)
  meta_tree_data["Root"][:children]["Child C"] = {
    :ui_content => ["Child C line1", "Child C line2", "Child C line3"],
    :children=> {}
  }
  ui.post_event(cmd: :update_tree, meta_tree_data: meta_tree_data)

  # Wait a bit, then stop
  sleep(15)
  ui.post_event(:stop)
  ui.join
  puts "Main thread: UI has shut down."
end