-----------------------------------------------------------------------
--               GtkAda - Ada95 binding for Gtk+/Gnome               --
--                                                                   --
--                   Copyright (C) 2001 ACT-Europe                   --
--                                                                   --
-- This library is free software; you can redistribute it and/or     --
-- modify it under the terms of the GNU General Public               --
-- License as published by the Free Software Foundation; either      --
-- version 2 of the License, or (at your option) any later version.  --
--                                                                   --
-- This library is distributed in the hope that it will be useful,   --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of    --
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU --
-- General Public License for more details.                          --
--                                                                   --
-- You should have received a copy of the GNU General Public         --
-- License along with this library; if not, write to the             --
-- Free Software Foundation, Inc., 59 Temple Place - Suite 330,      --
-- Boston, MA 02111-1307, USA.                                       --
--                                                                   --
-- As a special exception, if other files instantiate generics from  --
-- this unit, or you link this unit with other files to produce an   --
-- executable, this  unit  does not  by itself cause  the resulting  --
-- executable to be covered by the GNU General Public License. This  --
-- exception does not however invalidate any other reasons why the   --
-- executable file  might be covered by the  GNU Public License.     --
-----------------------------------------------------------------------

with Gdk.Color;       use Gdk.Color;
with Gdk.Event;       use Gdk.Event;
with Glib;            use Glib;
with Glib.Object;     use Glib.Object;
with Gtk.Arguments;   use Gtk.Arguments;
with Gtk.Clist;       use Gtk.Clist;
with Gtk.Enums;       use Gtk.Enums;
with Gtk.Label;       use Gtk.Label;
with Gtk.Main;        use Gtk.Main;
with Gtk.Menu;        use Gtk.Menu;
with Gtk.Menu_Item;   use Gtk.Menu_Item;
with Gtk.Notebook;    use Gtk.Notebook;
with Gtk.Scrolled_Window; use Gtk.Scrolled_Window;
with Gtk.Style;       use Gtk.Style;
with Gtk.Widget;      use Gtk.Widget;
with Gtkada.Handlers; use Gtkada.Handlers;
with Gtkada.MDI;      use Gtkada.MDI;
with Gtkada.Types;    use Gtkada.Types;

with Ada.Calendar;
with GNAT.Calendar.Time_IO;     use GNAT.Calendar.Time_IO;
with GNAT.Calendar;             use GNAT.Calendar;
with GNAT.Directory_Operations; use GNAT.Directory_Operations;
with GNAT.OS_Lib;               use GNAT.OS_Lib;
with Interfaces.C.Strings;      use Interfaces.C.Strings;
with Interfaces.C;              use Interfaces.C;

with Prj_API;              use Prj_API;
with Creation_Wizard;      use Creation_Wizard;
with Glide_Kernel;         use Glide_Kernel;
with Glide_Kernel.Preferences; use Glide_Kernel.Preferences;
with Glide_Kernel.Project; use Glide_Kernel.Project;
with Glide_Kernel.Modules; use Glide_Kernel.Modules;
with GUI_Utils;            use GUI_Utils;
with Switches_Editors;     use Switches_Editors;
with Directory_Tree;       use Directory_Tree;
with String_Utils;         use String_Utils;

with Prj;           use Prj;
with Stringt;       use Stringt;
with Types;         use Types;
with Namet;         use Namet;
with Snames;        use Snames;

with Switches_Editors; use Switches_Editors;

package body Project_Viewers is

   Prj_Editor_Module_ID : Module_ID;
   --  Id for the project editor module

   --  ??? Preferences
   Default_Project_Width  : constant := 400;
   Default_Project_Height : constant := 400;

   Project_Editor_Window_Name : constant String := "Project editor";

   type View_Display is access procedure
     (Viewer    : access Project_Viewer_Record'Class;
      File_Name : String;
      Directory : String;
      Fd        : File_Descriptor;
      Line      : out Interfaces.C.Strings.chars_ptr;
      Style     : out Gtk_Style);
   --  Procedure used to return the contents of one of the columns.
   --  The returned string (Line) will be freed by the caller.
   --  Style is the style to apply to the matching cell in the clist.

   type View_Callback is access procedure
     (Viewer    : access Project_Viewer_Record'Class;
      Column    : Gint;
      File_Name : String_Id;
      Directory : String_Id);
   --  Callback called every time the user selects a column in one of the
   --  view. The view is not passed as a parameter, but can be obtained
   --  directly from the Viewer, since this is the current view displayed in
   --  the viewer

   type View_Display_Array is array (Interfaces.C.size_t range <>)
     of View_Display;

   type View_Callback_Array is array (Interfaces.C.size_t range <>)
     of View_Callback;

   type View_Description (Num_Columns : Interfaces.C.size_t) is record
      Titles : Interfaces.C.Strings.chars_ptr_array (1 .. Num_Columns);
      --  The titles for all the columns

      Tab_Title : String_Access;
      --  The label for the notebook page that contains the view

      Display : View_Display_Array (1 .. Num_Columns);
      --  The functions to display each of the columns. null can be provided
      --  if the columns doesn't contain any information.

      Callbacks : View_Callback_Array (1 .. Num_Columns);
      --  The callbacks to call when a column is clicked. If null, no callback
      --  is called.
   end record;
   type View_Description_Access is access constant View_Description;

   procedure Name_Display
     (Viewer : access Project_Viewer_Record'Class;
      File_Name : String;
      Directory : String;
      Fd        : File_Descriptor;
      Line      : out Interfaces.C.Strings.chars_ptr;
      Style     : out Gtk_Style);
   --  Return the name of the file

   procedure Size_Display
     (Viewer : access Project_Viewer_Record'Class;
      File_Name : String;
      Directory : String;
      Fd        : File_Descriptor;
      Line      : out Interfaces.C.Strings.chars_ptr;
      Style     : out Gtk_Style);
   --  Return the size of the file

   procedure Timestamp_Display
     (Viewer : access Project_Viewer_Record'Class;
      File_Name : String;
      Directory : String;
      Fd        : File_Descriptor;
      Line      : out Interfaces.C.Strings.chars_ptr;
      Style     : out Gtk_Style);
   --  Return the timestamp for the file

   procedure Compiler_Switches_Display
     (Viewer : access Project_Viewer_Record'Class;
      File_Name : String;
      Directory : String;
      Fd        : File_Descriptor;
      Line      : out Interfaces.C.Strings.chars_ptr;
      Style     : out Gtk_Style);
   --  Return the switches used for the compiler

   procedure Edit_Switches_Callback
     (Viewer    : access Project_Viewer_Record'Class;
      Column    : Gint;
      File_Name : String_Id;
      Directory : String_Id);
   --  Called every time the user wans to edit some specific switches

   View_System : aliased constant View_Description :=
     (Num_Columns => 3,
      Titles      => "File Name" + "Size" + "Last_Modified",
      Tab_Title   => new String' ("System"),
      Display     => (Name_Display'Access,
                      Size_Display'Access,
                      Timestamp_Display'Access),
      Callbacks   => (null, null, null));

   View_Version_Control : aliased constant View_Description :=
     (Num_Columns => 3,
      Titles      => "File Name" + "Revision" + "Head Revision",
      Tab_Title   => new String' ("VCS"),
      Display     => (Name_Display'Access, null, null),
      Callbacks   => (null, null, null));

   View_Switches : aliased constant View_Description :=
     (Num_Columns => 2,
      Titles      => "File Name" + "Compiler",
      Tab_Title   => new String' ("Switches"),
      Display     => (Name_Display'Access,
                      Compiler_Switches_Display'Access),
      Callbacks   => (null,
                      Edit_Switches_Callback'Access));

   Views : array (View_Type) of View_Description_Access :=
     (View_System'Access, View_Version_Control'Access, View_Switches'Access);

   type User_Data is record
      File_Name : String_Id;
      Directory : String_Id;
   end record;
   package Project_User_Data is new Row_Data (User_Data);

   function Current_Page
     (Viewer : access Project_Viewer_Record'Class) return View_Type;
   pragma Inline (Current_Page);
   --  Return the view associated with the current page of Viewer.

   procedure Append_Line
     (Viewer           : access Project_Viewer_Record'Class;
      Project_View     : Project_Id;
      File_Name        : String_Id;
      Directory_Filter : String := "");
   --  Append a new line in the current page of Viewer, for File_Name.
   --  The exact contents inserted depends on the current view.
   --  The file is automatically searched in all the source directories of
   --  Project_View.

   function Append_Line_With_Full_Name
     (Viewer         : access Project_Viewer_Record'Class;
      Current_View   : View_Type;
      Project_View   : Project_Id;
      File_Name      : String;
      Directory_Name : String) return Gint;
   --  Same as above, except we have already found the proper location for
   --  the file.
   --  Return the number of the newly inserted row

   function Find_In_Source_Dirs
     (Project_View : Project_Id; File : String) return String_Id;
   --  Return the location of File in the source dirs of Project_View.
   --  null is returned if the file wasn't found.

   procedure Switch_Page
     (Viewer : access Gtk_Widget_Record'Class; Args : Gtk_Args);
   --  Callback when a new page is selected in Viewer.
   --  If the page is not up-to-date, we refresh its contents

   procedure Select_Row
     (Viewer : access Gtk_Widget_Record'Class; Args : Gtk_Args);
   --  Callback when a row/column has been selected in the clist

   procedure Explorer_Selection_Changed
     (Viewer  : access Gtk_Widget_Record'Class;
      Args    : Gtk_Args);
   --  Called every time the selection has changed in the tree

   function Viewer_Contextual_Menu
     (Viewer : access Gtk_Widget_Record'Class; Event : Gdk_Event)
      return Gtk_Menu;
   --  Return the contextual menu to use for the project viewer

   procedure Project_Editor_Contextual
     (Context   : access Selection_Context'Class;
      Menu      : access Gtk.Menu.Gtk_Menu_Record'Class);
   --  Add new entries, when needed, to the contextual menus from other
   --  modules.

   procedure Add_Directory_From_Contextual
     (Widget : access Gtk_Widget_Record'Class;
      Context : Selection_Context_Access);
   --  Callback for the contextual menu item to add some source directories

   procedure Change_Obj_Directory_From_Contextual
     (Widget : access Gtk_Widget_Record'Class;
      Context : Selection_Context_Access);
   --  Change the object directory associated with a specific project

   procedure On_New_Project
     (Widget : access GObject_Record'Class;
      Kernel : Kernel_Handle);
   --  Callback for the Project->New menu

   procedure On_Edit_Project
     (Widget : access GObject_Record'Class;
      Kernel : Kernel_Handle);
   --  Callback for the Project->Edit menu

   -------------------------
   -- Find_In_Source_Dirs --
   -------------------------

   function Find_In_Source_Dirs
     (Project_View : Project_Id; File : String) return String_Id
   is
      Dirs   : String_List_Id := Projects.Table (Project_View).Source_Dirs;
      File_A : String_Access;

   begin
      --  We do not use Ada_Include_Path to locate the source file,
      --  since this would include directories from imported project
      --  files, and thus slow down the search. Instead, we search
      --  in all the directories directly belong to the project.

      while Dirs /= Nil_String loop
         String_To_Name_Buffer (String_Elements.Table (Dirs).Value);
         File_A := Locate_Regular_File (File, Name_Buffer (1 .. Name_Len));

         if File_A /= null then
            Free (File_A);
            return String_Elements.Table (Dirs).Value;
         end if;

         Dirs := String_Elements.Table (Dirs).Next;
      end loop;

      return No_String;
   end Find_In_Source_Dirs;

   -------------------------------
   -- Compiler_Switches_Display --
   -------------------------------

   procedure Compiler_Switches_Display
     (Viewer : access Project_Viewer_Record'Class;
      File_Name : String;
      Directory : String;
      Fd        : File_Descriptor;
      Line      : out Interfaces.C.Strings.chars_ptr;
      Style     : out Gtk_Style)
   is
      File       : Name_Id;
      Value      : Variable_Value;
      Is_Default : Boolean;

   begin
      Name_Len := File_Name'Length;
      Name_Buffer (1 .. Name_Len) := File_Name;
      File := Name_Find;

      --  ??? Should show the switches for the specific language of the file
      Get_Switches
        (Viewer.Project_Filter, "compiler", File,
         Snames.Name_Ada, Value, Is_Default);
      Line := New_String (To_String (Value));

      if Is_Default then
         Style := Viewer.Default_Switches_Style;
      end if;
   end Compiler_Switches_Display;

   ------------------
   -- Name_Display --
   ------------------

   procedure Name_Display
     (Viewer    : access Project_Viewer_Record'Class;
      File_Name : String;
      Directory : String;
      Fd        : File_Descriptor;
      Line      : out Interfaces.C.Strings.chars_ptr;
      Style     : out Gtk_Style)
   is
      pragma Warnings (Off, Viewer);
      pragma Warnings (Off, Directory);
      pragma Warnings (Off, Fd);
   begin
      Style := null;
      Line  := New_String (File_Name);
   end Name_Display;

   ------------------
   -- Size_Display --
   ------------------

   procedure Size_Display
     (Viewer    : access Project_Viewer_Record'Class;
      File_Name : String;
      Directory : String;
      Fd        : File_Descriptor;
      Line      : out Interfaces.C.Strings.chars_ptr;
      Style     : out Gtk_Style)
   is
      pragma Warnings (Off, Viewer);
      pragma Warnings (Off, Directory);
      pragma Warnings (Off, File_Name);
   begin
      Style := null;
      Line := New_String (Long_Integer'Image (File_Length (Fd)));
   end Size_Display;

   -----------------------
   -- Timestamp_Display --
   -----------------------

   procedure Timestamp_Display
     (Viewer    : access Project_Viewer_Record'Class;
      File_Name : String;
      Directory : String;
      Fd        : File_Descriptor;
      Line      : out Interfaces.C.Strings.chars_ptr;
      Style     : out Gtk_Style)
   is
      pragma Warnings (Off, Viewer);
      pragma Warnings (Off, Directory);
      pragma Warnings (Off, File_Name);

      type Char_Pointer is access Character;

      type tm is record
         tm_sec    : Integer;
         tm_min    : Integer;
         tm_hour   : Integer;
         tm_mday   : Integer;
         tm_mon    : Integer;
         tm_year   : Integer;
         tm_wday   : Integer;
         tm_yday   : Integer;
         tm_isdst  : Integer;
         tm_gmtoff : Long_Integer;
         tm_zone   : Char_Pointer;
      end record;

      procedure localtime_r
        (C : in out OS_Time; res : out tm);
      pragma Import (C, localtime_r, "__gnat_localtime_r");

      T      : tm;
      A_Time : Ada.Calendar.Time;
      O_Time : OS_Time;

   begin
      O_Time := File_Time_Stamp (Fd);
      localtime_r (O_Time, T);

      --  Make sure the values returned by localtime are in the
      --  appropriate range

      T.tm_mon := T.tm_mon + 1;
      A_Time := Time_Of (1900 + T.tm_year, T.tm_mon, T.tm_mday,
                         T.tm_hour, T.tm_min, T.tm_sec);
      Line := New_String
        (Image (A_Time,
                Picture_String (Get_Pref (Viewer.Kernel, Timestamp_Picture))));
      Style := null;
   end Timestamp_Display;

   ----------------------------
   -- Edit_Switches_Callback --
   ----------------------------

   procedure Edit_Switches_Callback
     (Viewer    : access Project_Viewer_Record'Class;
      Column    : Gint;
      File_Name : String_Id;
      Directory : String_Id)
   is
      pragma Warnings (Off, Column);
   begin
      Edit_Switches
        (Kernel       => Viewer.Kernel,
         Project_View => Viewer.Project_Filter,
         File_Name    => File_Name,
         Directory    => Directory);
   end Edit_Switches_Callback;

   --------------------------------
   -- Append_Line_With_Full_Name --
   --------------------------------

   function Append_Line_With_Full_Name
     (Viewer         : access Project_Viewer_Record'Class;
      Current_View   : View_Type;
      Project_View   : Project_Id;
      File_Name      : String;
      Directory_Name : String) return Gint
   is
      Line      : Gtkada.Types.Chars_Ptr_Array
        (1 .. Views (Current_View).Num_Columns);
      Row       : Gint;
      File_Desc : File_Descriptor;
      Style     : array (1 .. Views (Current_View).Num_Columns) of Gtk_Style;

   begin
      if Is_Absolute_Path (Directory_Name) then
         File_Desc := Open_Read (Directory_Name & Directory_Separator
                                 & File_Name & ASCII.Nul, Text);
      else
         File_Desc := Open_Read
           (Get_Current_Dir & Directory_Name & Directory_Separator
            & File_Name & ASCII.Nul, Text);
      end if;

      for Column in Line'Range loop
         if Views (Current_View).Display (Column) /= null then
            Views (Current_View).Display (Column)
              (Viewer, File_Name, Directory_Name, File_Desc,
               Line (Column), Style (Column));
         else
            Line (Column) := New_String ("");
            Style (Column) := null;
         end if;
      end loop;

      Close (File_Desc);

      Row := Append (Viewer.Pages (Current_View), Line);

      for S in Style'Range loop
         Set_Cell_Style
           (Viewer.Pages (Current_View), Row, Gint (S - Style'First),
            Style (S));
      end loop;

      Free (Line);
      return Row;
   end Append_Line_With_Full_Name;

   -----------------
   -- Append_Line --
   -----------------

   procedure Append_Line
     (Viewer           : access Project_Viewer_Record'Class;
      Project_View     : Project_Id;
      File_Name        : String_Id;
      Directory_Filter : String := "")
   is
      Current_View : constant View_Type := Current_Page (Viewer);
      File_N       : String (1 .. Integer (String_Length (File_Name)));
      Dir_Name     : String_Id;

   begin
      String_To_Name_Buffer (File_Name);
      File_N := Name_Buffer (1 .. Name_Len);

      if Directory_Filter /= ""
        and then not Is_Regular_File
        (Directory_Filter & Directory_Separator & File_N)
      then
         return;
      end if;

      Dir_Name := Find_In_Source_Dirs (Project_View, File_N);
      pragma Assert (Dir_Name /= No_String);

      String_To_Name_Buffer (Dir_Name);
      Project_User_Data.Set
        (Viewer.Pages (Current_View),
         Append_Line_With_Full_Name
           (Viewer, Current_View, Project_View,
            File_N, Name_Buffer (1 .. Name_Len)),
         (File_Name => File_Name, Directory => Dir_Name));
   end Append_Line;

   -----------------
   -- Switch_Page --
   -----------------

   procedure Switch_Page
     (Viewer : access Gtk_Widget_Record'Class;
      Args   : Gtk_Args)
   is
      use type Row_List.Glist;

      V            : Project_Viewer := Project_Viewer (Viewer);
      Page_Num     : constant Guint := To_Guint (Args, 2);
      Current_View : View_Type := View_Type'Val (Page_Num);
      Up_To_Date   : View_Type;
      List         : Row_List.Glist;
      User         : User_Data;

   begin
      --  No current page (happens only while V is not realized)
      if Get_Current_Page (V) = -1 then
         return;
      end if;

      --  Nothing to do if the page is already up-to-date
      if V.Page_Is_Up_To_Date (Current_View) then
         return;
      end if;

      --  Otherwise, we update the list of files based on the contents of
      --  one of the up-to-date pages
      Up_To_Date := View_Type'First;

      loop
         exit when V.Page_Is_Up_To_Date (Up_To_Date);

         --  We haven't found an up-to-date page. This can happen for instance
         --  when Viewer is empty and has never been associated with a
         --  directory before.

         if Up_To_Date = View_Type'Last then
            return;
         end if;

         Up_To_Date := View_Type'Succ (Up_To_Date);
      end loop;

      Freeze (V.Pages (Current_View));
      Clear (V.Pages (Current_View));

      List := Get_Row_List (V.Pages (Up_To_Date));

      while List /= Row_List.Null_List loop
         User := Project_User_Data.Get
           (V.Pages (Up_To_Date), Row_List.Get_Data (List));

         declare
            N : String (1 .. Integer (String_Length (User.File_Name)));
            D : String (1 .. Integer (String_Length (User.Directory)));

         begin
            String_To_Name_Buffer (User.File_Name);
            N := Name_Buffer (1 .. Name_Len);

            String_To_Name_Buffer (User.Directory);
            D := Name_Buffer (1 .. Name_Len);

            Project_User_Data.Set
              (V.Pages (Current_View),
               Append_Line_With_Full_Name
                  (V, Current_View, V.Project_Filter, N, D),
               User);
         end;

         List := Row_List.Next (List);
      end loop;

      Thaw (V.Pages (Current_View));
      V.Page_Is_Up_To_Date (Current_View) := True;
   end Switch_Page;

   ----------------
   -- Select_Row --
   ----------------

   procedure Select_Row
     (Viewer : access Gtk_Widget_Record'Class; Args : Gtk_Args)
   is
      V            : Project_Viewer := Project_Viewer (Viewer);
      Current_View : constant View_Type := Current_Page (V);
      Row          : Gint := To_Gint (Args, 1);
      Column       : Gint := To_Gint (Args, 2);
      Event        : Gdk_Event := To_Event (Args, 3);
      User         : User_Data;
      Callback     : View_Callback;

   begin
      Callback := Views (Current_View).Callbacks
        (Interfaces.C.size_t (Column + 1));

      --  Event could be null when the row was selected programmatically
      if Event /= null
        and then Get_Event_Type (Event) = Gdk_2button_Press
        and then Callback /= null
      then
         User := Project_User_Data.Get (V.Pages (Current_View), Row);
         Callback (V, Column, User.File_Name, User.Directory);
      end if;
   end Select_Row;

   --------------------------------
   -- Explorer_Selection_Changed --
   --------------------------------

   procedure Explorer_Selection_Changed
     (Viewer  : access Gtk_Widget_Record'Class;
      Args    : Gtk_Args)
   is
      View         : Project_Viewer := Project_Viewer (Viewer);
      Current_View : constant View_Type := Current_Page (View);
      User         : User_Data;
      Rows         : Gint;
      Context      : Selection_Context_Access :=
        To_Selection_Context_Access (To_Address (Args, 1));
      File         : File_Selection_Context_Access;

   begin
      if Context.all in File_Selection_Context'Class then
         File := File_Selection_Context_Access (Context);
         View.Current_Project := Project_Information (File);

         Clear (View);  --  ??? Should delete selectively

         if View.Current_Project /= No_Project then
            Show_Project (View, View.Current_Project,
                          Directory_Information (File));
         end if;

         if Has_File_Information (File) then
            Rows := Get_Rows (View.Pages (Current_View));

            for J in 0 .. Rows - 1 loop
               User := Project_User_Data.Get (View.Pages (Current_View), J);

               if Get_String (User.File_Name) = File_Information (File) then
                  Select_Row (View.Pages (Current_View), J, 0);
                  return;
               end if;
            end loop;
         end if;
      end if;
   end Explorer_Selection_Changed;

   -------------
   -- Gtk_New --
   -------------

   procedure Gtk_New
     (Viewer   : out Project_Viewer;
      Kernel   : access Kernel_Handle_Record'Class) is
   begin
      Viewer := new Project_Viewer_Record;
      Project_Viewers.Initialize (Viewer, Kernel);
   end Gtk_New;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize
     (Viewer   : access Project_Viewer_Record'Class;
      Kernel   : access Kernel_Handle_Record'Class)
   is
      Label    : Gtk_Label;
      Color    : Gdk_Color;
      Scrolled : Gtk_Scrolled_Window;

   begin
      Gtk.Notebook.Initialize (Viewer);
      Register_Contextual_Menu (Viewer, Viewer_Contextual_Menu'Access);

      Viewer.Kernel := Kernel_Handle (Kernel);

      for View in View_Type'Range loop
         Gtk_New (Scrolled);
         Set_Policy (Scrolled, Policy_Automatic, Policy_Automatic);
         Gtk_New (Viewer.Pages (View),
                  Columns => Gint (Views (View).Num_Columns),
                  Titles  => Views (View).Titles);
         Add (Scrolled, Viewer.Pages (View));
         Set_Column_Auto_Resize (Viewer.Pages (View), 0, True);
         Gtk_New (Label, Views (View).Tab_Title.all);

         Widget_Callback.Object_Connect
           (Viewer.Pages (View), "select_row",  Select_Row'Access, Viewer);

         Append_Page (Viewer, Scrolled, Label);
      end loop;

      Widget_Callback.Connect (Viewer, "switch_page", Switch_Page'Access);

      Widget_Callback.Object_Connect
        (Kernel, Context_Changed_Signal,
         Explorer_Selection_Changed'Access,
         Viewer);

      Color := Get_Pref (Kernel, Default_Switches_Color);
      Viewer.Default_Switches_Style := Copy (Get_Style (Viewer));
      Set_Foreground (Viewer.Default_Switches_Style, State_Normal, Color);

      Show_All (Viewer);

      --  The initial contents of the viewer should be read immediately from
      --  the explorer, without forcing the user to do a new selection.
      --  ??? Explorer_Selection_Changed (Viewer);
   end Initialize;

   ----------------------------
   -- Viewer_Contextual_Menu --
   ----------------------------

   function Viewer_Contextual_Menu
     (Viewer : access Gtk_Widget_Record'Class;
      Event  : Gdk_Event) return Gtk_Menu
   is
      pragma Warnings (Off, Event);
      V : Project_Viewer := Project_Viewer (Viewer);
      Current_View : constant View_Type := Current_Page (V);
      Item : Gtk_Menu_Item;
      Row, Column : Gint;
      Is_Valid : Boolean;
      User : User_Data;

   begin
      if V.Contextual_Menu /= null then
         Destroy (V.Contextual_Menu);
         V.Contextual_Menu := null;
      end if;

      Get_Selection_Info
        (V.Pages (Current_View), Gint (Get_X (Event)), Gint (Get_Y (Event)),
         Row, Column, Is_Valid);

      if Is_Valid or else V.Project_Filter /= No_Project then
         Gtk_New (V.Contextual_Menu);
      end if;

      if V.Project_Filter /= No_Project then
         Gtk_New (Item, "Edit default switches");
         Add (V.Contextual_Menu, Item);
         Contextual_Callback.Connect
           (Item, "activate",
            Contextual_Callback.To_Marshaller
            (Edit_Switches_From_Contextual'Access),
            (Kernel    => V.Kernel,
             Project   => V.Project_Filter,
             File_Name => No_String,
             Directory => No_String));
      end if;

      if Is_Valid then
         User := Project_User_Data.Get (V.Pages (Current_View), Row);

         if User.File_Name /= No_String then
            String_To_Name_Buffer (User.File_Name);
            Gtk_New (Item, "Edit switches for "
                     & Name_Buffer (Name_Buffer'First .. Name_Len));
            Add (V.Contextual_Menu, Item);
            Contextual_Callback.Connect
              (Item, "activate",
               Contextual_Callback.To_Marshaller
               (Edit_Switches_From_Contextual'Access),
               (Kernel    => V.Kernel,
                Project   => V.Project_Filter,
                File_Name => User.File_Name,
                Directory => User.Directory));
         end if;
      end if;

      return V.Contextual_Menu;
   end Viewer_Contextual_Menu;

   ------------------
   -- Current_Page --
   ------------------

   function Current_Page
     (Viewer : access Project_Viewer_Record'Class) return View_Type
   is
      P : Gint := Get_Current_Page (Viewer);
   begin
      if P /= -1 then
         return View_Type'Val (P);
      else
         return View_Type'First;
      end if;
   end Current_Page;

   ------------------
   -- Show_Project --
   ------------------

   procedure Show_Project
     (Viewer           : access Project_Viewer_Record;
      Project_Filter   : Prj.Project_Id;
      Directory_Filter : String := "")
   is
      Src          : String_List_Id := Projects.Table (Project_Filter).Sources;
      Current_View : constant View_Type := Current_Page (Viewer);

   begin
      Viewer.Page_Is_Up_To_Date := (others => False);
      Viewer.Page_Is_Up_To_Date (Current_View) := True;
      Viewer.Project_Filter := Project_Filter;

      Freeze (Viewer.Pages (Current_View));

      while Src /= Nil_String loop
         Append_Line (Viewer, Project_Filter,
                      String_Elements.Table (Src).Value,
                      Directory_Filter);
         Src := String_Elements.Table (Src).Next;
      end loop;

      Thaw (Viewer.Pages (Current_View));
   end Show_Project;

   -----------
   -- Clear --
   -----------

   procedure Clear (Viewer : access Project_Viewer_Record) is
      Current_View : constant View_Type := Current_Page (Viewer);
   begin
      Viewer.Page_Is_Up_To_Date := (others => False);
      Viewer.Page_Is_Up_To_Date (Current_View) := True;

      Freeze (Viewer.Pages (Current_View));
      Clear (Viewer.Pages (Current_View));
      Thaw (Viewer.Pages (Current_View));
   end Clear;

   -----------------------------------
   -- Add_Directory_From_Contextual --
   -----------------------------------

   procedure Add_Directory_From_Contextual
     (Widget : access Gtk_Widget_Record'Class;
      Context : Selection_Context_Access)
   is
      Dirs : Argument_List :=
        Multiple_Directories_Selector_Dialog (Get_Current_Dir);
      File_Context : File_Selection_Context_Access :=
        File_Selection_Context_Access (Context);
   begin
      if Dirs'Length /= 0 then
         Update_Attribute_Value_In_Scenario
           (Project            => Get_Project_From_View
              (Project_Information (File_Context)),
            Pkg_Name           => "",
            Scenario_Variables => Scenario_Variables (Get_Kernel (Context)),
            Attribute_Name     => "source_dirs",
            Values             => Dirs,
            Attribute_Index    => No_String,
            Prepend            => True);
         Free (Dirs);
         Recompute_View (Get_Kernel (Context));
      end if;
   end Add_Directory_From_Contextual;

   ------------------------------------------
   -- Change_Obj_Directory_From_Contextual --
   ------------------------------------------

   procedure Change_Obj_Directory_From_Contextual
     (Widget  : access Gtk_Widget_Record'Class;
      Context : Selection_Context_Access)
   is
      Dir : constant String := Single_Directory_Selector_Dialog
        (Get_Current_Dir);
      File_Context : File_Selection_Context_Access :=
        File_Selection_Context_Access (Context);
   begin
      if Dir /= "" then
         Update_Attribute_Value_In_Scenario
           (Project            => Get_Project_From_View
              (Project_Information (File_Context)),
            Pkg_Name           => "",
            Scenario_Variables => Scenario_Variables (Get_Kernel (Context)),
            Attribute_Name     => "object_dir",
            Value              => Dir,
            Attribute_Index    => No_String);
         Recompute_View (Get_Kernel (Context));
      end if;
   end Change_Obj_Directory_From_Contextual;

   -------------------------------
   -- Project_Editor_Contextual --
   -------------------------------

   procedure Project_Editor_Contextual
     (Context   : access Selection_Context'Class;
      Menu      : access Gtk.Menu.Gtk_Menu_Record'Class)
   is
      Item : Gtk_Menu_Item;
      File_Context : File_Selection_Context_Access;
   begin
      --  We insert entries whatever the sender_id is, as long as the context
      --  knows something about project or files

      if Context.all in File_Selection_Context'Class then
         File_Context := File_Selection_Context_Access (Context);

         if Has_Project_Information (File_Context) then
            Gtk_New (Item, Label => "");
            Append (Menu, Item);

            Gtk_New (Item, Label => "Add Directory to "
                     & Project_Name (Project_Information (File_Context)));
            Append (Menu, Item);
            Context_Callback.Connect
              (Item, "activate",
               Context_Callback.To_Marshaller
               (Add_Directory_From_Contextual'Access),
               Selection_Context_Access (Context));

            Gtk_New (Item, Label => "Change Object Directory for "
                     & Project_Name (Project_Information (File_Context)));
            Append (Menu, Item);
            Context_Callback.Connect
              (Item, "activate",
               Context_Callback.To_Marshaller
               (Change_Obj_Directory_From_Contextual'Access),
               Selection_Context_Access (Context));

            Gtk_New (Item, Label => "Edit Default Switches for "
                     & Project_Name (Project_Information (File_Context)));
            Append (Menu, Item);
            --  Context_Callback.Connect
            --    (Item, "activate",
            --     Context_Callback.To_Marshaller
            --     (Edit_Switches_From_Contextual'Access),
            --     Selection_Context_Access (Context));
         end if;

         if Has_Directory_Information (File_Context) then
            Gtk_New (Item, Label => "");
            Append (Menu, Item);
            Gtk_New (Item, Label => "Remove Directory "
                     & Directory_Information (File_Context));
            Set_Sensitive (Item, False);
            Append (Menu, Item);
         end if;

         Gtk_New (Item, Label => "");
         Append (Menu, Item);
         Gtk_New (Item, Label => "Add Variable");
         Append (Menu, Item);
         --  Context_Callback.Connect
         --    (Item, "activate",
         --     Context_Callback.To_Marshaller
         --     (Add_Variable_Contextual'Access),
         --     Selection_Context_Access (Context));

         if Has_File_Information (File_Context) then
            Gtk_New (Item, Label => "");
            Append (Menu, Item);

            Gtk_New (Item, Label => "Edit Switches for "
                     & Base_File_Name (File_Information (File_Context)));
            Append (Menu, Item);
            --  Context_Callback.Connect
            --    (Item, "activate",
            --     Context_Callback.To_Marshaller
            --     (Edit_Switches_From_Contextual'Access),
            --     Selection_Context_Access (Context));

            --  ??? Should be in another module
            --  Gtk_New (Item, Label => File_Information (File_Context)
            --           & " depends on...");
            --  Append (Menu, Item);
            --  Context_Callback.Connect
            --    (Item, "activate",
            --     Context_Callback.To_Marshaller
            --     (Edit_Dependencies_From_Contextual'Access),
            --     Selection_Context_Access (Context));
         end if;
      end if;
   end Project_Editor_Contextual;

   --------------------
   -- On_New_Project --
   --------------------

   procedure On_New_Project
     (Widget : access GObject_Record'Class;
      Kernel : Kernel_Handle)
   is
      Wiz : Creation_Wizard.Prj_Wizard;
   begin
      Gtk_New (Wiz, Kernel);
      Set_Current_Page (Wiz, 1);
      Show_All (Wiz);
      Main;
   end On_New_Project;

   -------------------------
   -- On_Debug_Executable --
   -------------------------

   procedure On_Edit_Project
     (Widget : access GObject_Record'Class;
      Kernel : Kernel_Handle)
   is
      Child  : MDI_Child;
      Viewer : Project_Viewer;
   begin
      Child := Find_MDI_Child_By_Tag (Kernel, Project_Viewer_Record'Tag);

      if Child /= null then
         Raise_Child (Child);
      else
         Gtk_New (Viewer, Kernel);
         Set_Size_Request
           (Viewer, Default_Project_Width, Default_Project_Height);
         Child := Put (Get_MDI (Kernel), Viewer);
         Set_Title (Child, Project_Editor_Window_Name);
      end if;
   end On_Edit_Project;

   -----------------------
   -- Initialize_Module --
   -----------------------

   procedure Initialize_Module
     (Kernel : access Glide_Kernel.Kernel_Handle_Record'Class)
   is
      Menu_Item : Gtk_Menu_Item;
   begin
      Gtk_New (Menu_Item, "New...");
      Register_Menu (Kernel, "/Project", Menu_Item, Ref_Item => "Open...");
      Kernel_Callback.Connect
        (Menu_Item, "activate",
         Kernel_Callback.To_Marshaller (On_New_Project'Access),
         Kernel_Handle (Kernel));

      Gtk_New (Menu_Item, "Edit...");
      Register_Menu (Kernel, "/Project", Menu_Item, Ref_Item => "Open...",
                     Add_Before => False);
      Kernel_Callback.Connect
        (Menu_Item, "activate",
         Kernel_Callback.To_Marshaller (On_Edit_Project'Access),
         Kernel_Handle (Kernel));

      Gtk_New (Menu_Item, "Add Directory...");
      Register_Menu (Kernel, "/Project", Menu_Item, Ref_Item => "Edit...",
                     Add_Before => False);
   end Initialize_Module;

begin
   Prj_Editor_Module_ID := Register_Module
     (Module_Name             => Project_Editor_Module_Name,
      Priority                => Default_Priority,
      Initializer             => Initialize_Module'Access,
      Contextual_Menu_Handler => Project_Editor_Contextual'Access);
end Project_Viewers;
