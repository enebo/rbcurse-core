=begin
  * Name: TabularWidget
  * Description   A widget based on Tabular
  * Author: rk (arunachalesha)
  * file created 2010-09-28 23:37 
FIXME:

TODO 
   * guess_c : have some config : NEVER, FIRST_TIME, EACH_TIME
     if user has specified widths then we don't wanna guess. guess_size 20, ALL.
   * move columns
   * hide columns - importnat since with sorting we may need to store an identifier which 
     should not be displayed
   x data truncation based on col wid TODO
   * TODO: search -- how is it working, but curpos is wrong. This is since list does not contain
      header, it only has data. so curpos is off by one _header_adjustment
   * allow resize of column inside column header
   * Now that we allow header to get focus, we should allow it to handle
    keys, but its not an object like it was in rtable ! AARGH !
   * NOTE: header could become an object in near future, but then why did we break
   away from rtable ?
   * TODO FIXME : after converting to convert_value_to_text and truncation etc, numbering is broken
   * we are checking widths of columsn and we have added a column, so columns widths refer to wrong col
   TODO : tabbing with w to take care of hidden columns and numbering. FIXME
   TODO: we forgot about selection altogether. we need multiple select !!! as in gmail
         subject list.
  --------
  * License:
    Same as Ruby's License (http://www.ruby-lang.org/LICENSE.txt)

=end
require 'rbcurse'
require 'rbcurse/core/include/listscrollable'
require 'rbcurse/core/widgets/tabular'
require 'rbcurse/core/include/listselectable'
require 'rbcurse/core/include/bordertitle'

#include RubyCurses
module RubyCurses
  extend self
  # used when firing a column resize, so calling application can perhaps
  # resize other columns.
  class ColumnResizeEvent < Struct.new(:source, :index, :type); end

  ##
  # A viewable read only, scrollable table. This is supposed to be a
  # +minimal+, and (hopefully) fast version of Table (@see rtable.rb).
  class TabularWidget < Widget


    include ListScrollable
    include NewListSelectable
    #dsl_accessor :title   # set this on top
    #dsl_accessor :title_attrib   # bold, reverse, normal
    dsl_accessor :footer_attrib   # bold, reverse, normal
    dsl_accessor :list    # the array of arrays of data to be sent by user XXX RISKY bypasses set_content
    dsl_accessor :maxlen    # max len to be displayed
    attr_reader :toprow    # the toprow in the view (offsets are 0)
    ##attr_reader :winrow   # the row in the viewport/window
    # painting the footer does slow down cursor painting slightly if one is moving cursor fast
    dsl_accessor :print_footer
    #dsl_accessor :suppress_borders 
    attr_accessor :current_index
    #dsl_accessor :border_attrib, :border_color #  color pair for border
    dsl_accessor :header_attrib, :header_fgcolor, :header_bgcolor  #  2010-10-15 13:21 

    # boolean, whether lines should be cleaned (if containing tabs/newlines etc)
    dsl_accessor :sanitization_required
    # boolean, whether column widths should be estimated based on data. If you want this,
    # set to true each time you do a set_content
    dsl_accessor :estimate_column_widths
    # boolean, whether lines should be numbered
    attr_accessor :numbering
    # default or custom sorter
    attr_reader :table_row_sorter

    # @group select related
    dsl_accessor :selection_mode
    dsl_accessor :selected_color, :selected_bgcolor, :selected_attr

    dsl_property :show_selector # boolean
    dsl_property :row_selected_symbol 
    dsl_property :row_unselected_symbol 
    attr_accessor :selected_index # should we use only indices ??
    # index of selected rows, if multiple selection asked for
    attr_reader :selected_indices
    attr_reader :_header_adjustment # we need to adjust when using current_index !!! UGH
    # @endgroup select related
    attr_reader :columns

    def initialize form = nil, config={}, &block
      @focusable = true
      @editable = false
      @sanitization_required = true
      @estimate_column_widths = true
      @row = 0
      @col = 0
      @cw = {} # column widths keyed on column index - why not array ??
      @pw = [] # preferred column widths 2010-10-20 12:58 
      @calign = {} # columns aligns values, on column index
      @coffsets = {}
      @suppress_borders = false
      @row_offset = @col_offset = 1 
      @chash = {}
      # this should have index of displayed column
      # so user can reorder columns
      #@column_position = [] # TODO
      @separ = @columns = @numbering =  nil
      @y = '|'
      @x = '+'
      @list = []
      @_header_adjustment = 0
      @show_focus = false  # don't highlight row under focus TODO
      @selection_mode = :multiple # default is multiple, anything else given becomes single
      @row_selected_symbol = '*'
      @show_selector = true
      super
      # ideally this should have been 2 to take care of borders, but that would break
      # too much stuff !
      @win = @graphic

      @_events.push :CHANGE # thru vieditable
      @_events << :PRESS # new, in case we want to use this for lists and allow ENTER
      @_events << :ENTER_ROW # new, should be there in listscrollable ??
      @_events << :COLUMN_RESIZE_EVENT 
      install_keys # << almost jnuk now, clean off TODO
      init_vars
      map_keys
      bordertitle_init
    end
    def init_vars #:nodoc:
      @curpos = @pcol = @toprow = @current_index = 0
      @repaint_all=true 
      @repaint_required=true 

      @row_offset = @col_offset = 0 if @suppress_borders == true
      @internal_width = 2
      @internal_width = 0 if @suppress_borders
      # added 2010-02-11 15:11 RFED16 so we don't need a form.
      @current_column = 0
      # currently i scroll right only if  current line is longer than display width, i should use 
      # longest line on screen.
      @longest_line = 0 # the longest line printed on this page, used to determine if scrolling shd work
      list_init_vars

    end
    def map_keys
      require 'rbcurse/core/include/listbindings'
      bindings()
      bind_key(?w, :next_column)
      bind_key(?b, :previous_column)
      bind_key(?>, :expand_column) # just trying out
      list_bindings # selection bindings
    end

    #
    # set column names
    # @param [Array] column names or headings
    #
    def columns=(array)
      @_header_adjustment = 1
      @columns = array
      @columns.each_with_index { |c,i| 
        @cw[i] ||= c.to_s.length
        @calign[i] ||= :left
      }
      # maintains index in current pointer and gives next or prev
      @column_pointer = Circular.new @columns.size()-1
    end
    alias :headings= :columns=
      ## 
      # send in a list of data
      # sorting will only happen if data passed using set_content
      # NOTE: why doesn't set_content take in columns
      # @param [Array / Tabular] data to be displayed
      def set_content list, columns=nil
        if list.is_a? RubyCurses::Tabular
          @list = list
        elsif list.is_a? Array
          @list = list
        else
          raise "set_content expects Array not #{list.class}"
        end
        if @table_row_sorter
          @table_row_sorter.model=@list
        else
          @table_row_sorter = TableRowSorter.new @list
        end
        # adding columns setting here 2011-10-16 
        self.columns = columns if columns
        @current_index = @_header_adjustment # but this is set when columns passed
        @toprow = 0
        @second_time = false # so that reestimation of column_widths
        @repaint_required = true
        @recalc_required = true # is this used, if not remove TODO
        self
      end
    def data=(data)
      set_content(data, nil)
    end

    # add a row of data 
    #  NOTE: this is not creating a table sorter
    # @param [Array] an array containing entries for each column
    def add array
      @list ||= []
      @list << array
      @repaint_required = true
      @recalc_required = true
    end
    alias :<< :add
    alias :add_row :add
    alias :append :add
    def create_default_sorter
      raise "Data not sent in." unless @list
      @table_row_sorter = TableRowSorter.new @list
    end
    def remove_all
      @list = []
      init_vars
    end
    def delete_at off0
      @repaint_required = true
      @delete_buffer=@list.delete_at off0
      return @delete_buffer
    end
    def []=(off0, data)
      @repaint_required = true
      @list[off0] = data
    end
    def [](off0)
      @list[off0]
    end
    def insert off0, *data
      @repaint_required = true
      @list.insert off0, *data
    end

    # delete current line or lines
    # Should be using listeditable except for _header_adjustment
    # NOTE: user has to map this to some key such as 'dd'
    #  tw.bind_key([?\d,?\d]) { tw.delete_line }
    #
    def delete_line line=real_index()
      #return -1 unless @editable
      if !$multiplier || $multiplier == 0 
        @delete_buffer = @list.delete_at line
      else
        @delete_buffer = @list.slice!(line, $multiplier)
      end
      @curpos ||= 0 # rlist has no such var
      $multiplier = 0
      #add_to_kill_ring @delete_buffer
      @buffer = @list[@current_index]
      if @buffer.nil?
        up
        setrowcol @row + 1, nil # @form.col
      end
      # warning: delete buffer can now be an array
      #fire_handler :CHANGE, InputDataEvent.new(@curpos,@curpos+@delete_buffer.length, self, :DELETE_LINE, line, @delete_buffer)     #  2008-12-24 18:34 
      set_modified 
      #@widget_scrolled = true
      @repaint_required = true
    end

    # undo deleted row/rows, this is a simple undo, unlike undo_managers more
    # complete undo. I am not calling this <tt>undo</tt>, so there's no conflict with
    # undomanager if used.
    # NOTE: user has to map this to some key such as 'u'
    #     tw.bind_key(?\U) { tw.undo }
    #
    def undo_delete
      return unless @delete_buffer
      if @delete_buffer[0].is_a? Array
        # multiple rows deleted
        insert real_index(), *@delete_buffer
      else
        # one row deleted
        insert real_index(), @delete_buffer
      end
    end

    # TODO more methods like in listbox so interchangeable, delete_at etc
    def column_width colindex, width
      return if width < 0
      raise ArgumentError, "wrong width value sent: #{width} " if width.nil? || !width.is_a?(Integer) || width < 0
      @cw[colindex] = width # uncommented 2011-12-1 for expand on +
      @pw[colindex] = width # XXXXX
      get_column(colindex).width = width
      @repaint_required = true
      @recalc_required = true
    end

    # set alignment of given column offset
    # @param [Number] column offset, starting 0
    # @param [Symbol] :left, :right
    def column_align colindex, lrc
      raise ArgumentError, "wrong alignment value sent" if ![:right, :left, :center].include? lrc
      @calign[colindex] = lrc
      get_column(colindex).align = lrc
      @repaint_required = true
      #@recalc_required = true
    end
    # Set a column to hidden  TODO we are not actually doing that
    def column_hidden colindex, tf=true
      #raise ArgumentError, "wrong alignment value sent" if ![:right, :left, :center].include? lrc
      get_column(colindex).hidden = tf
      @repaint_required = true
      @recalc_required = true
    end
    def move_column

    end
    def expand_column
      x = _convert_curpos_to_column
      w = get_column(x).width || @cw[x]
      # sadly it seems to be nil
      column_width x, w+1 if w
    end
    def contract_column
      x = _convert_curpos_to_column
      w = get_column(x).width || @cw[x]
      column_width x, w-1 if w
    end
    ## display this row number on top
    # programmataically indicate a row to be top row
    def top_row(*val) 
      if val.empty?
        @toprow
      else
        @toprow = val[0] || 0
      end
      @repaint_required = true
    end
    ## ---- for listscrollable ---- ##
    def scrollatrow #:nodoc:
      # TODO account for headers
      if @suppress_borders
        @height - @_header_adjustment 
      else
        @height - (2 + @_header_adjustment) 
      end
    end
    def row_count
      #@list.length
      get_content().length + @_header_adjustment
    end
    ##
    # returns row of first match of given regex (or nil if not found)
    def find_first_match regex #:nodoc:
      @list.each_with_index do |row, ix|
        return ix if !row.match(regex).nil?
      end
      return nil
    end
    ## returns the position where cursor was to be positioned by default
    # It may no longer work like that. 
    def rowcol #:nodoc:
      return @row+@row_offset, @col+@col_offset
    end
    ## print a border
    ## Note that print_border clears the area too, so should be used sparingly.
    def OLDprint_borders #:nodoc:
      raise "#{self.class} needs width" unless @width
      raise "#{self.class} needs height" unless @height

      $log.debug " #{@name} print_borders,  #{@graphic.name} "

      bordercolor = @border_color || $datacolor
      borderatt = @border_attrib || Ncurses::A_NORMAL
      @graphic.print_border @row, @col, @height-1, @width, bordercolor, borderatt
      print_title
    end
    def OLDprint_title #:nodoc:
      raise "#{self.class} needs width" unless @width
      $log.debug " print_title #{@row}, #{@col}, #{@width}  "
      @graphic.printstring( @row, @col+(@width-@title.length)/2, @title, $datacolor, @title_attrib) unless @title.nil?
    end
    def print_foot #:nodoc:
      @footer_attrib ||= Ncurses::A_DIM
      gb = get_color($datacolor, 'green','black')
      if @current_index == @toprow
        footer = "%15s" % " [ header row ]"
      else
        footer = "%15s" % " [#{@current_index}/ #{@list.length} ]"
      end
      pos = @col + 2
      right = true
      if right
        pos = @col + @width - footer.length - 1
      end
      @graphic.printstring( @row + @height -1 , pos, footer, gb, @footer_attrib) 
      @repaint_footer_required = false # 2010-01-23 22:55 
      #@footer_attrib ||= Ncurses::A_REVERSE
      #footer = "R: #{@current_index+1}, C: #{@curpos+@pcol}, #{@list.length} lines  "
      ##$log.debug " print_foot calling printstring with #{@row} + #{@height} -1, #{@col}+2"
      #@graphic.printstring( @row + @height -1 , @col+2, footer, $datacolor, @footer_attrib) 
      #@repaint_footer_required = false # 2010-01-23 22:55 
    end
    ### FOR scrollable ###
    def get_content
      @list
      #[:columns, :separator,  *@list]
      #[:columns, *@list]
    end
    def get_window #:nodoc:
      @graphic
    end

    def repaint # Tabularwidget :nodoc:

      #return unless @repaint_required # 2010-02-12 19:08  TRYING - won't let footer print for col move
      paint if @repaint_required
      #  raise "TV 175 graphic nil " unless @graphic
      print_foot if @print_footer && @repaint_footer_required
    end
    def getvalue
      @list
    end
    # returns value of current row.
    # NOTE: you may need to adjust it with _header_adjustment - actually you can't
    # this may give wrong row -- depends what you want.
    def current_value
      @list[@current_index-@_header_adjustment] # XXX added header_adju 2010-11-01 11:14 
    end
    def real_index
      @current_index-@_header_adjustment # XXX added header_adju 2010-11-06 19:38 
    end
    # Tabularwidget
    def handle_key ch #:nodoc:
      if header_row?
        ret = header_handle_key ch
        return ret unless ret == :UNHANDLED
      end
      case ch
      when ?\C-a.getbyte(0) #, ?0.getbyte(0)
        # take care of data that exceeds maxlen by scrolling and placing cursor at start
        @repaint_required = true if @pcol > 0 # tried other things but did not work
        set_form_col 0
        @pcol = 0
      when ?\C-e.getbyte(0), ?$.getbyte(0)
        # take care of data that exceeds maxlen by scrolling and placing cursor at end
        # This use to actually pan the screen to actual end of line, but now somewhere
        # it only goes to end of visible screen, set_form probably does a sanity check
        blen = @buffer.rstrip.length
        set_form_col blen
        # search related 
      when KEY_ENTER, FFI::NCurses::KEY_ENTER
        #fire_handler :PRESS, self
        fire_action_event
      when ?0.getbyte(0)..?9.getbyte(0)
        # FIXME the assumption here was that if numbers are being entered then a 0 is a number
        # not a beg-of-line command.
        # However, after introducing universal_argument, we can enters numbers using C-u and then press another
        # C-u to stop. In that case a 0 should act as a command, even though multiplier has been set
        if ch == ?0.getbyte(0) and $multiplier == 0
          # copy of C-a - start of line
          @repaint_required = true if @pcol > 0 # tried other things but did not work
          set_form_col 0
          @pcol = 0
          return 0
        end
        # storing digits entered so we can multiply motion actions
        $multiplier *= 10 ; $multiplier += (ch-48)
        return 0
      when ?\C-c.getbyte(0)
        $multiplier = 0
        return 0
      else
        # check for bindings, these cannot override above keys since placed at end
        begin
          ret = process_key ch, self
        rescue => err
          $error_message.value = err.to_s
          #          @form.window.print_error_message # changed 2011 dts  
          $log.error " Tabularwidget ERROR #{err} "
          $log.debug(err.backtrace.join("\n"))
          textdialog ["Error in TabularWidget: #{err} ", *err.backtrace], :title => "Exception"
          # XXX caller app has no idea error occurred so can't do anything !
        end
        return :UNHANDLED if ret == :UNHANDLED
      end
      $multiplier = 0 # you must reset if you've handled a key. if unhandled, don't reset since parent could use
      set_form_row
      $status_message.value =  "F10 quit, F1 Help, : menu, toprow #{@toprow} current #{@current_index} " if $log.debug?
      return 0 # added 2010-01-12 22:17 else down arrow was going into next field
    end
    #
    # allow header to handle keys
    # NOTE: header could become an object in near future
    # We are calling a resize event and passing column index but do we really
    # have a column object that user can access and do something with ?? XXX
    #
    def header_handle_key ch   #:nodoc:
      # TODO pressing = should revert to calculated size ?
      col = _convert_curpos_to_column
      #width = @cw[col] 
      width = @pw[col] || @cw[col] 
      #alert "got width #{width}, #{@cw[col]} "
      # NOTE: we are setting pw and chash but paint picks from cw
      # TODO check for multiplier too
      case ch
      when ?-.getbyte(0)
        column_width col, width-1
        # if this event has not been used in a sample it could change in near future
        e = ColumnResizeEvent.new self, col,  :DECREASE
        fire_handler :COLUMN_RESIZE_EVENT, e
        # can fire_hander so user can resize another column
        return 0
      when ?\+.getbyte(0)
        column_width col, width+1
        # if this event has not been used in a sample it could change in near future
        e = ColumnResizeEvent.new self, col,  :INCREASE
        return 0
      end
      return :UNHANDLED
    end
    # newly added to check curpos when moving up or down
    def check_curpos #:nodoc:
      # if the cursor is ahead of data in this row then move it back
      # i don't think this is required
      return
      if @pcol+@curpos > @buffer.length
        addcol((@pcol+@buffer.length-@curpos)+1)
        @curpos = @buffer.length 
        maxlen = (@maxlen || @width-@internal_width)

        # even this row is gt maxlen, i.e., scrolled right
        if @curpos > maxlen
          @pcol = @curpos - maxlen
          @curpos = maxlen-1 
        else
          # this row is within maxlen, make scroll 0
          @pcol=0
        end
        set_form_col 
      end
    end
    # set cursor on correct column tview
    def set_form_col col1=@curpos #:nodoc:
      @cols_panned ||= 0
      @pad_offset ||= 0 # added 2010-02-11 21:54 since padded widgets get an offset.
      @curpos = col1
      maxlen = @maxlen || @width-@internal_width
      #@curpos = maxlen if @curpos > maxlen
      if @curpos > maxlen
        @pcol = @curpos - maxlen
        @curpos = maxlen - 1
        @repaint_required = true # this is required so C-e can pan screen
      else
        @pcol = 0
      end
      # the rest only determines cursor placement
      win_col = 0 # 2010-02-07 23:19 new cursor stuff
      col2 = win_col + @col + @col_offset + @curpos + @cols_panned + @pad_offset
      #$log.debug "TV SFC #{@name} setting c to #{col2} #{win_col} #{@col} #{@col_offset} #{@curpos} "
      #@form.setrowcol @form.row, col
      setrowcol nil, col2
      @repaint_footer_required = true
    end
    def cursor_forward #:nodoc:
      maxlen = @maxlen || @width-@internal_width
      repeatm { 
        if @curpos < @width and @curpos < maxlen-1 # else it will do out of box
          @curpos += 1
          addcol 1
        else
          @pcol += 1 if @pcol <= @buffer.length
        end
      }
      set_form_col 
      #@repaint_required = true
      @repaint_footer_required = true # 2010-01-23 22:41 
    end
    def addcol num #:nodoc:
      #@repaint_required = true
      @repaint_footer_required = true # 2010-01-23 22:41 
      if @form
        @form.addcol num
      else
        @parent_component.form.addcol num
      end
    end
    def addrowcol row,col #:nodoc:
      #@repaint_required = true
      @repaint_footer_required = true # 2010-01-23 22:41 
      if @form
        @form.addrowcol row, col
      else
        @parent_component.form.addrowcol num
      end
    end
    def cursor_backward  #:nodoc:
      repeatm { 
        if @curpos > 0
          @curpos -= 1
          set_form_col 
          #addcol -1
        elsif @pcol > 0 
          @pcol -= 1   
        end
      }
      #@repaint_required = true
      @repaint_footer_required = true # 2010-01-23 22:41 
    end

    ## NOTE: earlier print_border was called only once in constructor, but when
    ##+ a window is resized, and destroyed, then this was never called again, so the 
    ##+ border would not be seen in splitpane unless the width coincided exactly with
    ##+ what is calculated in divider_location.
    def paint  #:nodoc:
      my_win = nil
      if @form
        my_win = @form.window
      else
        my_win = @target_window
      end
      @graphic = my_win unless @graphic
      tm = get_content
      rc = tm.length
      _estimate_column_widths if rc > 0  # will set preferred_width 2011-10-4 
      @left_margin ||= @row_selected_symbol.length
      @width ||= @preferred_width

      @height ||= [tm.length+3, 10].min
      _prepare_format

      print_borders if (@suppress_borders == false && @repaint_all) # do this once only, unless everything changes
      _maxlen = @maxlen || @width-@internal_width
      tr = @toprow
      acolor = get_color $datacolor
      h = scrollatrow() 
      r,c = rowcol
      print_header
      r += @_header_adjustment # for column header
      @longest_line = @width #maxlen
      $log.debug " #{@name} Tabularwidget repaint width is #{@width}, height is #{@height} , maxlen #{maxlen}/ #{@maxlen}, #{@graphic.name} roff #{@row_offset} coff #{@col_offset}, r #{r} top #{toprow} ci #{current_index} "
      0.upto(h - @_header_adjustment) do |hh|
        crow = tr+hh
        if crow < rc
          #focussed = @current_index == crow ? true : false 
          content = tm[crow]

          columnrow = false
          if content == :columns
            columnrow = true
          end

          value = convert_value_to_text content, crow

          @buffer = value if crow == @current_index
          # next call modified string. you may wanna dup the string.
          # rlistbox does
          sanitize value if @sanitization_required
          truncate value
          ## set the selector symbol if requested
          paint_selector crow, r+hh, c, acolor, @attr

          #@graphic.printstring  r+hh, c, "%-*s" % [@width-@internal_width,value], acolor, @attr
          #print_data_row( r+hh, c, "%-*s" % [@width-@internal_width,value], acolor, @attr)
          print_data_row( r+hh, c+@left_margin, @width-@internal_width-@left_margin, value, acolor, @attr)

        else
          # clear rows
          @graphic.printstring r+hh, c, " " * (@width-@internal_width-@left_margin), acolor,@attr
        end
      end
      @repaint_required        = false
      @repaint_footer_required = true
      @repaint_all             = false

    end

    # print data rows
    def print_data_row r, c, len, value, color, attr
      @graphic.printstring  r, c, "%-*s" % [len,value], color, attr
    end
    #
    # Truncates data to fit into display area.
    #  Copied from listscrollable since we need to take care of left_margin
    #  2011-10-6 This may need to be reflected in listbox and others FIXME
    def truncate content  #:nodoc:
      #maxlen = @maxlen || @width-2
      _maxlen = @maxlen || @width-@internal_width
      _maxlen = @width-@internal_width if _maxlen > @width-@internal_width
      _maxlen -= @left_margin
      if !content.nil? 
        cl = content.length
        if cl > _maxlen # only show maxlen
          @longest_line = cl if cl > @longest_line
          ## taking care of when scrolling is needed but longest_line is misreported
          # So we scroll always and need to check 2013-03-06 - 00:09 
          #content.replace content[@pcol..@pcol+_maxlen-1] 
          content.replace(content[@pcol..@pcol+maxlen-1] || " ")
        else
          #content.replace content[@pcol..-1] if @pcol > 0
          content.replace(content[@pcol..-1]||" ") if @pcol > 0 
        end
      end
      content
    end

    # print header row
    #  allows user to override
    def print_header_row r, c, len, value, color, attr
      #acolor = $promptcolor
      @graphic.printstring  r, c+@left_margin, "%-*s" % [len-@left_margin ,value], color, attr
    end
    def separator
      #return @separ if @separ
      str = ""
      if @numbering
        rows = @list.size.to_s.length
        str = "-"*(rows+1)+@x
      end
      @cw.each_pair { |k,v| str << "-" * (v+1) + @x }
      @separ = str.chop
    end
    # prints the column headers
    # Uses +convert_value_to_text+ and +print_header_row+
    def print_header
      r,c = rowcol
      value = convert_value_to_text :columns, 0
      len = @width - @internal_width
      truncate value # else it can later suddenly exceed line
      @header_color_pair ||= get_color $promptcolor, @header_fgcolor, @header_bgcolor
      @header_attrib ||= @attr
      print_header_row r, c, len, value, @header_color_pair, @header_attrib
    end
    # convert data object to a formatted string for print
    # NOTE: useful for overriding and doing custom formatting
    # @param [Array] array of column data, mostly +String+
    #        Can also be :columns or :separator
    # @param [Integer] index of row in data
    def convert_value_to_text r, count
      if r == :separator
        return separator
      elsif r == :columns
        return "??" unless @columns # column was requested but not supplied
        # FIXME putting entire header into this, take care of hidden
        r = []
        @columns.each_with_index { |e, i| r << e unless get_column(i).hidden  }
        return @headerfmtstr % r if @numbering
      end
      str = ""

      if @numbering
        #r = r.dup
        #r.insert 0, count+1
        # TODO get the width
        str << "%*d |"%  [2, count + 1]
      end
      # unroll r, get width and align
      # This is to truncate column to requested width
      fmta = []
      r.each_with_index { |e, i| 
        next if get_column(i).hidden == true
        #w = @pw[i] || @cw[i]  # XXX
        #$log.debug "WIDTH XXX  #{i} w= #{w} , #{@pw[i]}, #{@cw[i]} :: #{e} " if $log.debug? 
        w = @cw[i]
        l = e.to_s.length
        fmt = "%-#{w}s "
        # if value is longer than width, then truncate it
        if l > w
          fmt = "%.#{w}s "
        else
          # ack we don;t need to recalc this we can pull out of hash FIXME
          case @calign[i]
          when :right
            fmt = "%#{w}s "
          else
            fmt = "%-#{w}s "
          end
        end
        str << fmt % e
        fmta << fmt
      }
      #fmstr = fmta.join(@y)
      #return fmstr % r; # FIXME hidden column still goes int 
      return str
    end
    # perhaps we can delete this since it does not respect @pw
    # @deprecated  (see _estimate_column_widths)
    def _guess_col_widths  #:nodoc:
      return if @second_time
      @second_time = true if @list.size > 0
      @list.each_with_index { |r, i| 
        break if i > 10
        next if r == :separator
        r.each_with_index { |c, j|
          x = c.to_s.length
          if @cw[j].nil?
            @cw[j] = x
          else
            @cw[j] = x if x > @cw[j]
          end
        }
      }
      #sum = @cw.values.inject(0) { |mem, var| mem + var  }
      #$log.debug " SUM is #{sum} "
      total = 0
      @cw.each_pair { |name, val| total += val }
      @preferred_width = total + (@cw.size() *2)
      @preferred_width += 4 if @numbering # FIXME this 4 is rough
    end
    def _estimate_column_widths  #:nodoc:
      return unless @estimate_column_widths
      @estimate_column_widths = false # XXX testing why its failing in gmail
      @columns.each_with_index { |c, i|  
        if @pw[i]
          @cw[i] = @pw[i]
        else
          @cw[i] = calculate_column_width(i)
        end
      }
      total = 0
      @cw.each_pair { |name, val| total += val }
      @preferred_width = total + (@cw.size() *2)
      @preferred_width += 4 if @numbering # FIXME this 4 is rough
    end
    # if user has not specified preferred_width for a column
    # then we can calculate the same based on data
    def calculate_column_width col
      ret = @cw[col] || 2
      ctr = 0
      @list.each_with_index { |r, i| 
        #next if i < @toprow # this is also a possibility, it checks visible rows
        break if ctr > 10
        ctr += 1
        next if r == :separator
        c = r[col]
        x = c.to_s.length
        ret = x if x > ret
      }
      ret
    end
    def _prepare_format  #:nodoc:
      @fmtstr = nil
      fmt = []
      total = 0
      @cw.each_with_index { |c, i| 
        next if get_column(i).hidden == true # added 2010-10-28 19:08 
        w = @cw[i]
        @coffsets[i] = total
        total += w + 2

        case @calign[i]
        when :right
          fmt << "%#{w}s "
        else
          fmt << "%-#{w}s "
        end
      }
      @fmstr = fmt.join(@y)
      if @numbering
        @rows ||= @list.size.to_s.length
        @headerfmtstr = " "*(@rows+1)+@y + @fmstr
        @fmstr = "%#{@rows}d "+ @y + @fmstr
        @coffsets.each_pair { |name, val| @coffsets[name] = val + @rows + 2 }
      end
      #$log.debug " FMT : #{@fmstr} "
      #alert "format:     #{@fmstr} "
    end
    ##
    # dynamically load a module and execute init method.
    # Hopefully, we can get behavior like this such as vieditable or multibuffers
    # TODO CUT THIS OUT AND FIX IT, there are simpler ways like extend()
    def load_module requirename, includename
      require "rbcurse/#{requirename}"
      extend Object.const_get("#{includename}")
      send("#{requirename}_init") #if respond_to? "#{includename}_init"
    end

    # returns true if cursor is on header row
    # NOTE: I have no idea why row was used here. it is not working
    def header_row?
      return false if @columns.nil?
      #1 == @row + (@current_index-@toprow)
      @current_index == @toprow
    end
    # on pressing ENTER we send user some info, the calling program
    # would bind :PRESS
    # Added a call to sort, should i still call PRESS
    # or just do a sort in here and not call PRESS ???
    #--
    # FIXME we can create this once and reuse
    #++
    def fire_action_event
      return unless @list
      return unless @table_row_sorter
      require 'rbcurse/core/include/ractionevent'
      # the header event must only be used if columns passed
      if header_row?
        # TODO we need to fire correct even for header row, including
        #alert "you are on header row: #{@columns[x]} curpos: #{@curpos}, x:#{x} "
        #aev = TextActionEvent.new self, :PRESS, @columns[x], x, @curpos
        x = _convert_curpos_to_column
        @table_row_sorter.toggle_sort_order x
        @table_row_sorter.sort
        @repaint_required = true
        aev = TextActionEvent.new self, :PRESS,:header, x, @curpos
      else
        # please check this again current_value due to _header_adjustment XXX test
        aev = TextActionEvent.new self, :PRESS, current_value(), @current_index, @curpos
      end
      fire_handler :PRESS, aev
    end
    # Convert current cursor position to a table column
    # calculate column based on curpos since user may not have
    # user w and b keys (:next_column)
    # @return [Integer] column index base 0
    def _convert_curpos_to_column  #:nodoc:
      x = 0
      @coffsets.each_pair { |e,i| 
        if @curpos < i 
          break
        else 
          x += 1
        end
      }
      x -= 1 # since we start offsets with 0, so first auto becoming 1
      return x
    end
    def on_enter
      # so cursor positioned on correct row
      set_form_row
      super
    end
    # called by listscrollable, used by scrollbar ENTER_ROW
    def on_enter_row arow
      fire_handler :ENTER_ROW, self
      @repaint_required = true
    end
    # move cursor to next column
    # FIXME need to account for hidden columns and numbering
    def next_column
      c = @column_pointer.next
      cp = @coffsets[c] 
      #$log.debug " next_column #{c} , #{cp} "
      @curpos = cp if cp
      next_row() if c < @column_pointer.last_index
      #addcol cp
      set_form_col 
    end
    def previous_column
      c = @column_pointer.previous
      cp = @coffsets[c] 
      #$log.debug " prev_column #{c} , #{cp} "
      @curpos = cp if cp
      previous_row() if c > @column_pointer.last_index
      #addcol cp FIXME
      set_form_col 
    end
    private
    def get_column index   #:nodoc:
      return @chash[index] if @chash.has_key? index
      @chash[index] = ColumnInfo.new
    end

    # Some supporting classes

    # This is our default table row sorter.
    # It does a multiple sort and allows for reverse sort also.
    # It's a pretty simple sorter and uses sort, not sort_by.
    # Improvements welcome.
    # Usage: provide model in constructor or using model method
    # Call toggle_sort_order(column_index) 
    # Call sort. 
    # Currently, this sorts the provided model in-place. Future versions
    # may maintain a copy, or use a table that provides a mapping of model to result.
    # # TODO check if column_sortable
    class TableRowSorter
      attr_reader :sort_keys
      def initialize model=nil
        self.model = model
        @columns_sort = []
        @sort_keys = nil
      end
      def model=(model)
        @model = model
        @sort_keys = nil
      end
      def sortable colindex, tf
        @columns_sort[colindex] = tf
      end
      def sortable? colindex
        return false if @columns_sort[colindex]==false
        return true
      end
      # should to_s be used for this column
      def use_to_s colindex
        return true # TODO
      end
      # sorts the model based on sort keys and reverse flags
      # @sort_keys contains indices to sort on
      # @reverse_flags is an array of booleans, true for reverse, nil or false for ascending
      def sort
        return unless @model
        return if @sort_keys.empty?
        $log.debug "TABULAR SORT KEYS #{sort_keys} "
        @model.sort!{|x,y| 
          res = 0
          @sort_keys.each { |ee| 
            e = ee.abs-1 # since we had offsetted by 1 earlier
            abse = e.abs
            if ee < 0
              res = y[abse] <=> x[abse]
            else
              res = x[e] <=> y[e]
            end
            break if res != 0
          }
          res
        }
      end
      # toggle the sort order if given column offset is primary sort key
      # Otherwise, insert as primary sort key, ascending.
      def toggle_sort_order index
        index += 1 # increase by 1, since 0 won't multiple by -1
        # internally, reverse sort is maintained by multiplying number by -1
        @sort_keys ||= []
        if @sort_keys.first && index == @sort_keys.first.abs
          @sort_keys[0] *= -1 
        else
          @sort_keys.delete index # in case its already there
          @sort_keys.delete(index*-1) # in case its already there
          @sort_keys.unshift index
          # don't let it go on increasing
          if @sort_keys.size > 3
            @sort_keys.pop
          end
        end
      end
      def set_sort_keys list
        @sort_keys = list
      end
    end #class
    # what about is_resizable XXX
    class ColumnInfo < Struct.new(:name, :width, :align, :hidden)
    end

    # a structure that maintains position and gives
    # next and previous taking max index into account.
    # it also circles. Can be used for traversing next component
    # in a form, or container, or columns in a table.
    class Circular < Struct.new(:max_index, :current_index)
      attr_reader :last_index
      attr_reader :current_index
      def initialize  m, c=0
        raise "max index cannot be nil" unless m
        @max_index = m
        @current_index = c
        @last_index = c
      end
      def next
        @last_index = @current_index
        if @current_index + 1 > @max_index
          @current_index = 0
        else
          @current_index += 1
        end
      end
      def previous
        @last_index = @current_index
        if @current_index - 1 < 0
          @current_index = @max_index
        else
          @current_index -= 1
        end
      end
      def is_last?
        @current_index == @max_index
      end
    end
    # for some compatibility with Table
    def set_data data, colnames_array
      set_content data
      columns = colnames_array
    end
    def get_column_name index
      @columns[index]
    end
    alias :column_name :get_column_name
    alias :column :get_column
    def method_missing(name, *args)
      name = name.to_s
      case name 
      when 'cell_editing_allowed', 'editing_policy'
        # silently ignore to keep compatible with Table
      else
        raise NoMethodError, "Undefined method #{name} for TabularWidget"
      end
    end

  end # class tabluarw

end # modul
if __FILE__ == $PROGRAM_NAME

  require 'rbcurse/core/util/app'
  App.new do
    t = TabularWidget.new @form, :row => 2, :col => 2, :height => 20, :width => 30
    t.columns = ["Name ", "Age ", " Email        "]
    t.add %w{ rahul 33 r@ruby.org }
    t << %w{ _why 133 j@gnu.org }
    t << ["jane", "1331", "jane@gnu.org" ]
    t.column_align 1, :right
    t.create_default_sorter

    s = TabularWidget.new @form, :row => 2, :col =>32  do |b|
      b.columns = %w{ country continent text }
      b << ["india","asia","a warm country" ] 
      b << ["japan","asia","a cool country" ] 
      b << ["russia","europe","a hot country" ] 
      #b.column_width 2, 30
    end
    s.create_default_sorter
    s = TabularWidget.new @form , :row => 12, :col => 32  do |b|
      b.columns = %w{ place continent text }
      b << ["india","asia","a warm country" ] 
      b << ["japan","asia","a cool country" ] 
      b << ["russia","europe","a hot country" ] 
      b << ["sydney","australia","a dry country" ] 
      b << ["canberra","australia","a dry country" ] 
      b << ["ross island","antarctica","a dry country" ] 
      b << ["mount terror","antarctica","a windy country" ] 
      b << ["mt erebus","antarctica","a cold place" ] 
      b << ["siberia","russia","an icy city" ] 
      b << ["new york","USA","a fun place" ] 
      b.column_width 0, 12
      b.column_width 1, 12
      b.column_hidden 1, true
      b.numbering = true ## FIXME BROKEN
    end
    s.create_default_sorter
    require 'rbcurse/core/widgets/scrollbar'
    sb = Scrollbar.new @form, :parent => s
    #t.column_align 1, :right
    #puts t.to_s
    #puts
  end
end
