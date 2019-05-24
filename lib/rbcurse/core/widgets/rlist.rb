=begin
  * Name: rlistbox: basic scrollable lists - no editing, see editablelistbox of more
  * Description   
  * Author: rkumar (arunachalesha)
  * Date: 2010-09-26 16:00 
  * License: Same as Ruby's License (http://www.ruby-lang.org/LICENSE.txt)
  * 
TODO 
  [x] removed Popup, ListDataEvent and ListDataModel !
  [x] XXX Can we separate editing out. Make a ReadonlyList, and extend it as EditableList. This way the usual
  use case remains cleaner.

CHANGES
  - 2011-11-18 changed name to list

=end
require 'rbcurse'
require 'rbcurse/core/include/listcellrenderer'
require 'rbcurse/core/include/bordertitle'
#require 'rbcurse/extras/include/listkeys'
require 'forwardable'


module RubyCurses
  extend self
  ##
  ## 
  # scrollable, selectable list of items
  #    - @selected contains indices of selected objects.
  ##
  ##
  # A readonly control for displaying a list of data or values. 
  # Although user editing is not allowed, but the list may be repopulated
  # as in a directory listing, or a list dependent on some other control's value.
  # This is not a drop-in replacement for Listbox as it drops many methods that are redundant.
  # Default selection is single, as opposed to Listbox.
  #
  class List < Widget

    require 'rbcurse/core/include/listscrollable'
    require 'rbcurse/core/include/listselectable'             # added 2011-10-8 
    include ListScrollable
    include NewListSelectable                           # added 2011-10-8 
    extend Forwardable
    #dsl_accessor :height # << widget already has this
    #dsl_accessor :title
    #dsl_property :title_attrib   # bold, reverse, normal
#   dsl_accessor :list    # the array of data to be sent by user
    attr_reader :toprow
    #dsl_accessor :default_values  # array of default values
    #dsl_accessor :is_popup       # if it is in a popup and single select, selection closes
    attr_accessor :current_index
    # selection mode multiple, single and none (none added 2011-12-26)
    dsl_accessor :selection_mode
    dsl_accessor :selected_color, :selected_bgcolor, :selected_attr
    dsl_accessor :max_visible_items   # how many to display 2009-01-11 16:15 
    #dsl_accessor :cell_editing_allowed
    dsl_property :show_selector # boolean
    dsl_property :row_selected_symbol # 2009-01-12 12:01 changed from selector to selected
    dsl_property :row_unselected_symbol # added 2009-01-12 12:00 
    dsl_property :left_margin
    # please set these in he constructor block. Settin them later will have no effect
    # since i would have bound them to actions
    attr_accessor :one_key_selection # will pressing a single key select or not
    # set to true if data could have newlines, tabs, and other stuff, def true
    dsl_accessor :sanitization_required
    # set to true if cell-renderer data can exceed width of listbox, default true
    # if you are absolutely sure that data is constant width, set to false.
    dsl_accessor :truncation_required
    #dsl_accessor :suppress_borders #to_print_borders
    dsl_accessor :justify # will be picked up by renderer
    # index of selected row
    attr_accessor :selected_index
    # index of selected rows, if multiple selection asked for
    dsl_accessor :selected_indices

    dsl_accessor :should_show_focus

    # basic listbox constructor
    #
    def initialize form=nil, config={}, &block
      @focusable = true
      @editable = false
      @sanitization_required = true # cleanup control and non print chars
      @truncation_required = true
      @suppress_borders = false #to_print_borders = 1
      #@row_selected_symbol = '' # thi sprevents default value from being set
      @row = 0
      @col = 0
      # data of listbox this is not an array, its a pointer to the  listdatamodel
      @list = nil 
      # any special attribs such as status to be printed in col1, or color (selection)
      @list_attribs = {}
      @current_index = 0
      @selected_indices = []
      @selected_index = nil
      @row_offset = @col_offset = 1
      @should_show_focus = true # Here's its on since the cellrenderer will show it on repaint
      @one_key_selection = false # use vim keys
      @selection_mode = :multiple # default is multiple, anything else given becomes single
      super
      @_events.push(*[:ENTER_ROW, :LEAVE_ROW, :LIST_SELECTION_EVENT, :PRESS])
      # I have moved this here so user can override keys.
      map_keys unless @keys_mapped
      @win = @graphic    # 2010-01-04 12:36 BUFFERED  replace form.window with graphic
      @win_left = 0
      @win_top = 0

      init_vars
      @internal_width = 2
      #@internal_width = 0 if @suppress_borders # NOTE it is 1 in bordertitle
      bordertitle_init

      if @list && !@selected_index.nil?  # XXX
        set_focus_on @selected_index # the new version
      end
      init_actions
    end
    # this is called several times, from constructor
    # and when list data changed, so only put relevant resets here.
    def init_vars
      @repaint_required = true
      @widget_scrolled = true  # 2011-10-15 
      @toprow = @pcol = 0
      if @show_selector
        @row_selected_symbol ||= '>'
        @row_unselected_symbol ||= ' '
        @left_margin ||= @row_selected_symbol.length
      end
      @row_selected_symbol ||= ''
      #@left_margin ||= 0
      @one_key_selection = false if @one_key_selection.nil?
      @row_offset = @col_offset = 0 if @suppress_borders

    end
    def map_keys
      return if @keys_mapped
      require 'rbcurse/core/include/listbindings'
      bindings()
      bind_key(?f, 'next row starting with char'){ ask_selection_for_char() }
      bind_key(?\M-v, 'toggle one_key_selection'){ @one_key_selection = !@one_key_selection }
      bind_key(13, 'fire action event'){ fire_action_event }
      list_bindings unless @selection_mode == :none  # listselectable
      @keys_mapped = true

    end

    ## returns count of row, needed by scrollbar and others.
    def row_count
      return 0 if @list.nil?
      @list.length
    end
    # start scrolling when user reaches this row
    def scrollatrow #:nodoc:
      if @suppress_borders
        return @height - 1
      else
        return @height - 3
      end
    end
    # provide data to List in the form of an Array or Variable or
    # ListDataModel. This will create a default ListSelectionModel.
    #
    # CHANGE as on 2010-09-21 12:53:
    # If explicit nil passed then dummy datamodel and selection model created
    # From now on, constructor will call this, so this can always
    # happen.
    #
    # NOTE: sometimes this can be added much after its painted.
    # Do not expect this to be called from constructor, although that
    # is the usual case. it can be dependent on some other list or tree.
    # @param [Array, Variable, ListDataModel] data to populate list with
    # @return [ListDataModel] just created or assigned
    
    def list *val
      return @list if val.empty?
      alist = val[0]
      case alist
      when Array
        @list = alist
        # I possibly should call init_vars in these 3 cases but am doing the minimal 2013-04-10 - 18:27 
        # Based no issue: https://github.com/rkumar/rbcurse/issues/15
        @current_index = @toprow = @pcol = 0
      when NilClass
          @list = [] # or nil ?
          @current_index = @toprow = @pcol = 0
      when Variable
        @list = alist.value
        @current_index = @toprow = @pcol = 0
      else
        raise ArgumentError, "Listbox list(): do not know how to handle #{alist.class} " 
      end
      clear_selection
    
      @repaint_required = true
      @widget_scrolled = true  # 2011-10-15 
      @list
    end
    def list_data_model; @list; end
    # conv method to insert data, trying to keep names same across along with Tabular, TextView,
    # TextArea and listbox. Don;t use this till i am certain.
    def data=(val)
      list(val)
    end
    # get element at
    # @param [Integer] index for element
    # @return [Object] element
    # @since 1.2.0  2010-09-06 14:33 making life easier for others.
    def [](off0)
      @list[off0]
    end
    # return object under cursor
    # Note: this should not be confused with selected row/s. User may not have selected this.
    # This is only useful since in some demos we like to change a status bar as a user scrolls down
    # @since 1.2.0  2010-09-06 14:33 making life easier for others.
    def current_value
      @list[@current_index]
    end
    def remove_all
      return if @list.nil? || @list.empty? 
      @list = []
      init_vars
    end
    def_delegators :@list, :include?, :each, :values, :size
    %w[ insert clear delete_at []= << ].each { |e| 
      eval %{
      def #{e}(*args)
         @list.send(:#{e}, *args)
         @widget_scrolled = true
         @repaint_required = true
      end
      }
    }
    def append text
      @list.push text
      @widget_scrolled = true
      @repaint_required = true
    end
    # avoid using "row", i'd rather stick with "index" and "value".
    alias :current_row :current_value
    alias :text :current_value  # thanks to shoes, not sure how this will impact since widget has text.

    ### START FOR scrollable ###
    def get_content
      @list 
    end
    def get_window #:nodoc:
      @graphic 
    end
    ### END FOR scrollable ###
    # override widgets text
    # returns indices of selected rows
    def getvalue
      selected_rows
    end
    # Listbox
    def handle_key(ch) #:nodoc:
      #map_keys unless @keys_mapped
      @current_index ||= 0
      @toprow ||= 0
      #h = scrollatrow()
      #rc = row_count
      #$log.debug " basiclistbox got ch #{ch}"
      #$log.debug " when kps #{@KEY_PREV_SELECTION}  "
      case ch
      #when 32
        #return if is_popup and @selection_mode == 'single' # not allowing select this way since there will be a difference 
        #toggle_row_selection @current_index #, @current_index
        #@repaint_required = true
      #when 0 # c-space
        #add_to_selection
      #when @KEY_NEXT_SELECTION # ?'
        #$log.debug "insdie next selection"
        #@oldrow = @current_index
        #do_next_selection 
        #bounds_check
      #when @KEY_PREV_SELECTION # ?"
        #@oldrow = @current_index
        #$log.debug "insdie prev selection"
        #do_prev_selection 
        #bounds_check
      #when @KEY_CLEAR_SELECTION
        #clear_selection 
        #@repaint_required = true
      when 27, ?\C-c.getbyte(0)
        $multiplier = 0
      when @KEY_BLOCK_SELECTOR
        mark_block #selection
      #when ?\C-u.getbyte(0)
        # multiplier. Series is 4 16 64
        # TESTING @multiplier = (@multiplier == 0 ? 4 : @multiplier *= 4)
      #  return 0
      #when ?\C-c.getbyte(0)
        #@multiplier = 0
        #return 0
      else
        # this has to be fixed, if compo does not handle key it has to continue into next part FIXME
        ret = :UNHANDLED # changed on 2009-01-27 13:14 not going into unhandled, tab not released
        if ret == :UNHANDLED
          # beware one-key eats up numbers. we'll be wondering why
          if @one_key_selection
            case ch
            #when ?A.getbyte(0)..?Z.getbyte(0), ?a.getbyte(0)..?z.getbyte(0), ?0.getbyte(0)..?9.getbyte(0)
            when ?A.getbyte(0)..?Z.getbyte(0), ?a.getbyte(0)..?z.getbyte(0)
              # simple motion, key press defines motion
              ret = set_selection_for_char ch.chr
            else
              ret = process_key ch, self
              @multiplier = 0
              # if no block associated with :PRESS (KEY_ENTER) lets allow the form to use ENTER
              # This is for default buttons. Added NO_BLOCK 2011-12-2 
              # 2011-12-2 11:54 PM this was resulting in no repaint even
              # when symbols were being executed??
              # Its risky since symbol can call something which returns
              # UNHNDLED or NO_BLOCK even tho' it executed.
              return :UNHANDLED if ret == :UNHANDLED #|| ret == :NO_BLOCK
            end
          else
            # no motion on single key, we can freak out like in vim, pref f <char> for set_selection
            case ch
            when ?0.getbyte(0)..?9.getbyte(0)
              $multiplier *= 10 ; $multiplier += (ch-48)
              #$log.debug " setting mult to #{$multiplier} in list "
              return 0
            end
            ret = process_key ch, self
            # if no block associated with :PRESS (KEY_ENTER) lets allow the form to use ENTER
            # This is for default buttons. Added NO_BLOCK 2011-12-2 
            return :UNHANDLED if ret == :UNHANDLED #|| ret == :NO_BLOCK1
          end
        end
      end
      $multiplier = 0
    end
    # 
    # triggered on hitting ENTER button
    #
    def fire_action_event
      require 'rbcurse/core/include/ractionevent'
      fire_handler :PRESS, ActionEvent.new(self, :PRESS, text)
    end
    # get a keystroke from user and go to first item starting with that key
    def ask_selection_for_char
      ch = @graphic.getch
      if ch < 0 || ch > 255
        return :UNHANDLED
      end
      ret = set_selection_for_char ch.chr
    end
    def ask_search_forward
        regex =  get_string("Enter regex to search")
        ix = @list.find_match regex
        if ix.nil?
          alert("No matching data for: #{regex}")
        else
          set_focus_on(ix)
        end
    end
    # gets string to search and calls data models find prev
    def ask_search_backward
      regex =  get_string("Enter regex to search (backward)")
      @last_regex = regex
      ix = @list.find_prev regex, @current_index
      if ix.nil?
        alert("No matching data for: #{regex}")
      else
        set_focus_on(ix)
      end
    end
    # please check for error before proceeding
    # @return [Boolean] false if no data
    def on_enter
      if @list.nil? || @list.size == 0
        Ncurses.beep
        return :UNHANDLED
      end
      super  # forgot this 2011-10-9 that's why events not firign
      on_enter_row @current_index
      set_form_row # added 2009-01-11 23:41 
      true
    end
    def on_enter_row arow
      # copied from resultsettextview, can this not be in one place like listscrollable ? FIXME
      if @should_show_focus
        highlight_focussed_row :FOCUSSED
        unless @oldrow == @selected_index
          highlight_focussed_row :UNFOCUSSED
        end
      end
      fire_handler :ENTER_ROW, self
      @repaint_required = true
    end
    def on_leave_row arow
      fire_handler :LEAVE_ROW, self
    end
    # getter and setter for cell_renderer
    # NOTE: due to our optimization of not repainting unless data has changed
    # or scrolling has happened, highlighting focus will repaint the row if you've
    # colored it. In that case, set <tt>show_show_focus</tt> to false
    def cell_renderer(*val)
      if val.empty?
        @cell_renderer ||= create_default_cell_renderer
      else
        @cell_renderer = val[0] 
      end
    end
    def create_default_cell_renderer
      return ListCellRenderer.new "", {"color"=>@color, "bgcolor"=>@bgcolor, "parent" => self, "display_length"=> @width-@internal_width-@left_margin}
      #return BasicListCellRenderer.new "", {"color"=>@color, "bgcolor"=>@bgcolor, "parent" => self, "display_length"=> @width-2-@left_margin}
    end
    ##
    # this method chops the data to length before giving it to the
    # renderer, this can cause problems if the renderer does some
    # processing. also, it pans the data horizontally giving the renderer
    # a section of it.
    def repaint #:nodoc:
      return unless @repaint_required
      #
      # TRYING OUT dangerous 2011-10-15 
      @repaint_required = false
      @repaint_required = true if @widget_scrolled || @pcol != @old_pcol || @record_changed || @property_changed

      unless @repaint_required
        unhighlight_row @old_selected_index
        highlight_selected_row
      end
      return unless @repaint_required
      $log.debug "BASICLIST REPAINT WILL HAPPEN #{current_index} "
      # not sure where to put this, once for all or repeat 2010-02-17 23:07 RFED16
      my_win = @form ? @form.window : @target_window
      @graphic = my_win unless @graphic
      raise " #{@name} neither form, nor target window given LB paint " unless my_win
      raise " #{@name} NO GRAPHIC set as yet                 LB paint " unless @graphic
      raise "width or height not given w:#{@width} , h:#{@height} " if @width.nil? || @height.nil?
      @win_left = my_win.left
      @win_top = my_win.top
      @left_margin ||= @row_selected_symbol.length
      # we are making sure display len does not exceed width XXX hope this does not wreak havoc elsewhere
      _dl = [@display_length || 100, @width-@internal_width-@left_margin].min # 2011-09-17 RK overwriting when we move grabbar in vimsplit

      $log.debug "basiclistbox repaint  #{@name} graphic #{@graphic}"
      #$log.debug "XXX repaint to_print #{@to_print_borders} "
      print_borders unless @suppress_borders # do this once only, unless everything changes
      #maxlen = @maxlen || @width-2
      tm = list()
      rc = row_count
      @longest_line = @width
      $log.debug " rbasiclistbox #{row_count}, w:#{@width} , maxlen:#{@maxlen} "
      if rc > 0     # just added in case no data passed
        tr = @toprow
        acolor = get_color $datacolor
        h = scrollatrow()
        r,c = rowcol
        0.upto(h) do |hh|
          crow = tr+hh
          if crow < rc
            _focussed = @current_index == crow ? true : false  # row focussed ?
            focus_type = _focussed 
            focus_type = :SOFT_FOCUS if _focussed && !@focussed
            selected = is_row_selected crow
            content = tm[crow]   # 2009-01-17 18:37 chomp giving error in some cases says frozen
            content = convert_value_to_text content, crow # 2010-09-23 20:12 
            # by now it has to be a String
            if content.is_a? String
              content = content.dup
              sanitize content if @sanitization_required
              truncate content if @truncation_required
            end
            ## set the selector symbol if requested
            selection_symbol = ''
            if @show_selector
              if selected
                selection_symbol = @row_selected_symbol
              else
                selection_symbol =  @row_unselected_symbol
              end
              @graphic.printstring r+hh, c, selection_symbol, acolor,@attr
            end
            #renderer = get_default_cell_renderer_for_class content.class.to_s
            renderer = cell_renderer()
            renderer.display_length = _dl # 2011-09-17 RK overwriting when we move grabbar in vimsplit
            renderer.repaint @graphic, r+hh, c+@left_margin, crow, content, focus_type, selected
          else
            # clear rows
            @graphic.printstring r+hh, c, " " * (@width-@internal_width), acolor,@attr
          end
        end
      end # rc == 0
      @repaint_required = false
      # 2011-10-13 
      @widget_scrolled = false
      @record_changed = false
      @property_changed = false
      @old_pcol = @pcol
    end
    def highlight_selected_row r=nil, c=nil, acolor=nil
      return unless @selected_index # no selection
      r = _convert_index_to_printable_row(@selected_index) unless r
      return unless r # not on screen
      unless c
        _r, c = rowcol
      end
      acolor ||= get_color $promptcolor, @selected_color, @selected_bgcolor
      att = FFI::NCurses::A_REVERSE
      att = get_attrib(@selected_attrib) if @selected_attrib
      @graphic.mvchgat(y=r, x=c, @width-@internal_width-@left_margin, att , acolor , nil)
    end
    def unhighlight_row index,  r=nil, c=nil, acolor=nil
      return unless index # no selection
      r = _convert_index_to_printable_row(index) unless r
      return unless r # not on screen
      unless c
        _r, c = rowcol
      end
      acolor ||= get_color $datacolor
      att = FFI::NCurses::A_NORMAL
      att = get_attrib(@normal_attrib) if @normal_attrib
      @graphic.mvchgat(y=r, x=c, @width-@internal_width-@left_margin, att , acolor , nil)
    end
    # the idea here is to allow users who subclass Listbox to easily override parts of the cumbersome repaint
    # method. This assumes your List has some data, but you print a lot more. Now you don't need to
    # change the data in the renderer, or keep formatted data in the list itself.
    # e.g. @list contains file names, or File objects, and this converts to a long listing.
    # If the renderer did that, the truncation would be on wrong data.
    # @since 1.2.0
    def convert_value_to_text value, crow
      case value
      when TrueClass, FalseClass
        value
      else
        value.to_s if value
      end
    end
    # takes a block, this way anyone extending this klass can just pass a block to do his job
    # This modifies the string
    def sanitize content #:nodoc:
      if content.is_a? String
        content.chomp!
        content.gsub!(/\t/, '  ') # don't display tab
        content.gsub!(/[^[:print:]]/, '')  # don't display non print characters
      else
        content
      end
    end
    # returns only the visible portion of string taking into account display length
    # and horizontal scrolling. MODIFIES STRING
    def truncate content # :nodoc:
      maxlen = @maxlen || @width-@internal_width
      maxlen = @width-@internal_width if maxlen > @width-@internal_width
      if maxlen == 0 # (otherwise it becoems -1 below)
        content.replace ""
        return
      end
      if !content.nil? 
        cl = content.length
        if cl > maxlen # only show maxlen
          @longest_line = cl if cl > @longest_line
          #content = content[@pcol..@pcol+maxlen-1] 
          ## taking care of when scrolling is needed but longest_line is misreported
          # So we scroll always and need to check 2013-03-06 - 00:09 
          content.replace(content[@pcol..@pcol+maxlen-1] || " ")
        else
          ## taking care of when scrolling is needed but longest_line is misreported
          # So we scroll always and need to check 2013-03-06 - 00:09 
          content.replace(content[@pcol..-1]||" ") if @pcol > 0 
        end
      end
      content
    end

    # be informed when data has changed. required here, was being called by listdatamodel earlier
    def list_data_changed
      if row_count == 0 # added on 2009-02-02 17:13 so cursor not hanging on last row which could be empty
        init_vars
        @current_index = 0
        set_form_row
      end
      @widget_scrolled = true  # 2011-10-15 
      @repaint_required = true
    end

    # set cursor column position
    # if i set col1 to @curpos, i can move around left right if key mapped
    def set_form_col col1=0               #:nodoc:
      @cols_panned ||= 0 
      # editable listboxes will involve changing cursor and the form issue
      win_col = 0 
      col2 = win_col + @col + @col_offset + col1 + @cols_panned + @left_margin
      $log.debug " set_form_col in rlistbox #{@col}+ left_margin #{@left_margin} ( #{col2} ) "
      setrowcol nil, col2 
    end

    # @group selection related
    
    # change selection of current row on pressing space bar
    # If mode is multiple, then other selections are cleared and this is added
    # NOTE: 2011-10-8 allow multiple select on spacebar. Using C-Space was quite unfriendly
    # although it will still work
    def OLDtoggle_row_selection crow=@current_index
      @repaint_required = true
      row = crow
      case @selection_mode 
      when :multiple
        add_to_selection
        #clear_selection
        #@selected_indices[0] = crow #@current_index
      else
        if @selected_index == crow #@current_index
          @selected_index = nil
          lse = ListSelectionEvent.new(crow, crow, self, :DELETE)
          fire_handler :LIST_SELECTION_EVENT, lse
        else
          @selected_index = crow #@current_index
          lse = ListSelectionEvent.new(crow, crow, self, :INSERT)
          fire_handler :LIST_SELECTION_EVENT, lse
        end
      end
    end
   #
    # Only for multiple mode.
    # add an item to selection, if selection mode is multiple
    # if item already selected, it is deselected, else selected
    # typically bound to Ctrl-Space
    def OLDadd_to_selection
      crow = @current_index
      case @selection_mode 
      when :multiple
        if @selected_indices.include? @current_index
          @selected_indices.delete @current_index
          lse = ListSelectionEvent.new(crow, crow, self, :DELETE)
          fire_handler :LIST_SELECTION_EVENT, lse
        else
          @selected_indices << @current_index
          lse = ListSelectionEvent.new(crow, crow, self, :INSERT)
          fire_handler :LIST_SELECTION_EVENT, lse
        end
      else
      end
      @repaint_required = true
    end
    # clears selected indices
    def OLDclear_selection
      @selected_indices = []
      @repaint_required = true
    end
    def OLDis_row_selected crow=@current_index
      case @selection_mode 
      when :multiple
        @selected_indices.include? crow
      else
        crow == @selected_index
      end
    end
    alias :is_selected? is_row_selected
    def goto_next_selection
      return if selected_rows().length == 0 
      row = selected_rows().sort.find { |i| i > @current_index }
      row ||= @current_index
      @current_index = row
      @repaint_required = true # fire list_select XXX
    end
    def goto_prev_selection
      return if selected_rows().length == 0 
      row = selected_rows().sort{|a,b| b <=> a}.find { |i| i < @current_index }
      row ||= @current_index
      @current_index = row
      @repaint_required = true # fire list_select XXX
    end
    # Returns selected indices
    # Indices are often required since the renderer may modify the values displayed
    #
    def get_selected_indices; @selected_indices; end

    # Returns selected values
    #
    def get_selected_values
      selected = []
      @selected_indices.each { |i| selected << @list[i] }
      return selected
    end
    alias :selected_values :get_selected_values
 
    # Define actions that can be popped up by PromptMenu or other menubar
    # Currently, only PromptMenu, but we can start contextually appending to Menubar or others
    def init_actions
      am = action_manager()
      am.add_action(Action.new("&Disable selection") { @selection_mode = :none; unbind_key(32); bind_key(32, :scroll_forward); } )
      am.add_action(Action.new("&Edit Toggle") { @edit_toggle = !@edit_toggle; $status_message.value = "Edit toggle is #{@edit_toggle}" })
    end


    # ADD HERE
  end # class listb


end # module
