-----------------------------------------------------------------------
--                          G L I D E  I I                           --
--                                                                   --
--                        Copyright (C) 2001                         --
--                            ACT-Europe                             --
--                                                                   --
-- GLIDE is free software; you can redistribute it and/or modify  it --
-- under the terms of the GNU General Public License as published by --
-- the Free Software Foundation; either version 2 of the License, or --
-- (at your option) any later version.                               --
--                                                                   --
-- This program is  distributed in the hope that it will be  useful, --
-- but  WITHOUT ANY WARRANTY;  without even the  implied warranty of --
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU --
-- General Public License for more details. You should have received --
-- a copy of the GNU General Public License along with this library; --
-- if not,  write to the  Free Software Foundation, Inc.,  59 Temple --
-- Place - Suite 330, Boston, MA 02111-1307, USA.                    --
-----------------------------------------------------------------------

with Glib;                         use Glib;
with Gtk.Main;                     use Gtk.Main;
with Gtk.Stock;                    use Gtk.Stock;
with Gtk.Window;                   use Gtk.Window;
with Gtkada.Dialogs;               use Gtkada.Dialogs;
with Gtkada.File_Selector;         use Gtkada.File_Selector;
with Gtkada.File_Selector.Filters; use Gtkada.File_Selector.Filters;

with Glide_Intl;              use Glide_Intl;

with GVD.Status_Bar;          use GVD.Status_Bar;

with Glide_Kernel;            use Glide_Kernel;
with Glide_Kernel.Console;    use Glide_Kernel.Console;
with Glide_Kernel.Modules;    use Glide_Kernel.Modules;
with Glide_Kernel.Project;    use Glide_Kernel.Project;

with Glide_Main_Window;       use Glide_Main_Window;

with GVD.Dialogs;             use GVD.Dialogs;

with GNAT.Expect;               use GNAT.Expect;
with GNAT.Regpat;               use GNAT.Regpat;
with GNAT.OS_Lib;               use GNAT.OS_Lib;
with GNAT.Directory_Operations; use GNAT.Directory_Operations;

with Factory_Data;            use Factory_Data;

with Ada.Exceptions;          use Ada.Exceptions;
with Traces;                  use Traces;

package body Glide_Menu is

   Me : Debug_Handle := Create ("Menu");

   type Help_Context is
     (Welcome_Help,
      GVD_Help,
      GNAT_UG_Help,
      GNAT_RM_Help,
      ARM95_Help,
      GDB_Help,
      GCC_Help);

   --------------------
   -- Menu Callbacks --
   --------------------

   procedure On_Close
     (Object : Data_Type_Access;
      Action : Guint;
      Widget : Limited_Widget);
   --  File->Close menu

   procedure On_Save_Desktop
     (Object : Data_Type_Access;
      Action : Guint;
      Widget : Limited_Widget);
   --  File->Save Desktop menu

   procedure On_Exit
     (Object : Data_Type_Access;
      Action : Guint;
      Widget : Limited_Widget);
   --  File->Exit menu

   procedure On_Preferences
     (Object : Data_Type_Access;
      Action : Guint;
      Widget : Limited_Widget);
   --  Edit->Preferences menu

   procedure On_Open_Project
     (Object : Data_Type_Access;
      Action : Guint;
      Widget : Limited_Widget);
   --  Project->Open menu

   procedure On_Build
     (Object : Data_Type_Access;
      Action : Guint;
      Widget : Limited_Widget);
   --  Build->Make menu

   procedure On_Run
     (Object : Data_Type_Access;
      Action : Guint;
      Widget : Limited_Widget);
   --  Build->Run menu

   procedure On_Stop_Build
     (Object : Data_Type_Access;
      Action : Guint;
      Widget : Limited_Widget);
   --  Build->Stop Build menu

   procedure On_Manual
     (Object : Data_Type_Access;
      Action : Guint;
      Widget : Limited_Widget);
   --  Help->Manual menu

   procedure On_About_Glide
     (Object : Data_Type_Access;
      Action : Guint;
      Widget : Limited_Widget);
   --  Help->About menu

   -----------------------------
   -- Misc internal functions --
   -----------------------------

   procedure Refresh;
   --  Handle pending graphical events.

   -------------
   -- Refresh --
   -------------

   procedure Refresh is
      Dead : Boolean;
   begin
      while Gtk.Main.Events_Pending loop
         Dead := Main_Iteration;
      end loop;
   end Refresh;

   ---------------------
   -- On_Open_Project --
   ---------------------

   procedure On_Open_Project
     (Object : Data_Type_Access;
      Action : Guint;
      Widget : Limited_Widget)
   is
      File_Selector : File_Selector_Window_Access;
   begin
      Gtk_New (File_Selector, "/", Get_Current_Dir, -"Open Project");
      Register_Filter (File_Selector, Prj_File_Filter);

      declare
         Filename : constant String := Select_File (File_Selector);
      begin
         if Filename /= "" then
            Load_Project (Glide_Window (Object).Kernel, Filename);
         end if;
      end;

   exception
      when E : others =>
         Trace (Me, "Unexpected exception: " & Exception_Information (E));
   end On_Open_Project;

   --------------
   -- On_Close --
   --------------

   procedure On_Close
     (Object : Data_Type_Access;
      Action : Guint;
      Widget : Limited_Widget) is
   begin
      null;

   exception
      when E : others =>
         Trace (Me, "Unexpected exception: " & Exception_Information (E));
   end On_Close;

   -------------
   -- On_Exit --
   -------------

   procedure On_Exit
     (Object : Data_Type_Access;
      Action : Guint;
      Widget : Limited_Widget)
   is
      Button : constant Message_Dialog_Buttons :=
        Message_Dialog
          (Msg            => -"Are you sure you want to quit ?",
           Dialog_Type    => Confirmation,
           Buttons        => Button_Yes or Button_No,
           Default_Button => Button_No,
           Parent         => Gtk_Window (Object));
   begin
      if Button = Button_Yes then
         Main_Quit;
      end if;

   exception
      when E : others =>
         Trace (Me, "Unexpected exception: " & Exception_Information (E));
   end On_Exit;

   ---------------------
   -- On_Save_Desktop --
   ---------------------

   procedure On_Save_Desktop
     (Object : Data_Type_Access;
      Action : Guint;
      Widget : Limited_Widget)
   is
      Top  : constant Glide_Window := Glide_Window (Object);
   begin
      Save_Desktop (Top.Kernel);

   exception
      when E : others =>
         Trace (Me, "Unexpected exception: " & Exception_Information (E));
   end On_Save_Desktop;

   --------------------
   -- On_Preferences --
   --------------------

   procedure On_Preferences
     (Object : Data_Type_Access;
      Action : Guint;
      Widget : Limited_Widget) is
   begin
      null;

   exception
      when E : others =>
         Trace (Me, "Unexpected exception: " & Exception_Information (E));
   end On_Preferences;

   --------------
   -- On_Build --
   --------------

   procedure On_Build
     (Object : Data_Type_Access;
      Action : Guint;
      Widget : Limited_Widget)
   is
      Top       : constant Glide_Window := Glide_Window (Object);
      Fd        : Process_Descriptor;
      Matched   : Match_Array (0 .. 0);
      Result    : Expect_Match;
      Args      : Argument_List_Access;
      Matcher   : constant Pattern_Matcher := Compile
        ("completed ([0-9]+) out of ([0-9]+) \((.*)%\)\.\.\.$",
         Multiple_Lines);
      Title     : String_Access;
      --  ??? Should get the name of the real main
      Project   : constant String := Get_Project_File_Name (Top.Kernel);
      Cmd       : constant String :=
        "gnatmake -P" & Project & " "
        & Scenario_Variables_Cmd_Line (Top.Kernel)
        & " ";

   begin
      if Get_Current_Explorer_Context (Top.Kernel) /= null then
         Title := new String'
           (File_Information (File_Selection_Context_Access (
             Get_Current_Explorer_Context (Top.Kernel))));
      else
         return;
      end if;

      Set_Busy (Top.Kernel, True);

      if Project = "" then
         --  This is the default internal project

         Args := Argument_String_To_List ("gnatmake -d " & Title.all);
         Console.Insert (Top.Kernel, "gnatmake " & Title.all, False);

      else
         Args := Argument_String_To_List (Cmd & Title.all & " -d");
         Console.Insert (Top.Kernel, Cmd & Title.all, False);
      end if;

      Top.Interrupted := False;
      Non_Blocking_Spawn
        (Fd, Args (Args'First).all, Args (Args'First + 1 .. Args'Last),
         Err_To_Out  => True);

      loop
         Refresh;

         if Top.Interrupted then
            Interrupt (Fd);
            Console.Insert (Top.Kernel, "<^C>");
         end if;

         Expect (Fd, Result, ".+", Timeout => 50);

         declare
            S : constant String := Expect_Out (Fd);
         begin
            Match (Matcher, S, Matched);

            if Matched (0) = No_Match then
               Console.Insert (Top.Kernel, S, Add_LF => False);
            else
               Print_Message
                 (Top.Statusbar, GVD.Status_Bar.Help,
                  S (S'First + 1 .. S'Last));
            end if;
         end;
      end loop;

      --  Note: The loop above can only exit via an exception (expected
      --  exception is Process_Died), so put any clean up code in the handlers
      --  below, not here.

   exception
      when Process_Died =>
         Free (Title);
         Console.Insert (Top.Kernel, Expect_Out (Fd), Add_LF => False);
         --  ??? Check returned status.

         Set_Busy (Top.Kernel, False);

         if Top.Interrupted then
            Top.Interrupted := False;
            Print_Message
              (Top.Statusbar, GVD.Status_Bar.Help,
               -"build interrupted.");
         else
            Print_Message
              (Top.Statusbar, GVD.Status_Bar.Help,
               -"build completed.");
         end if;

         Close (Fd);

      when E : others =>
         Free (Title);
         Close (Fd);
         Set_Busy (Top.Kernel, False);
         Trace (Me, "Unexpected exception: " & Exception_Information (E));
   end On_Build;

   ------------
   -- On_Run --
   ------------

   procedure On_Run
     (Object : Data_Type_Access;
      Action : Guint;
      Widget : Limited_Widget)
   is
      Arguments : constant String := Simple_Entry_Dialog
        (Parent  => Object,
         Title   => -"Arguments Selection",
         Message => -"Enter the arguments to your application:",
         Key     => "glide_run_arguments");

   begin
      if Arguments = ""
        or else Arguments (Arguments'First) /= ASCII.NUL
      then
         null;
      end if;

   exception
      when E : others =>
         Trace (Me, "Unexpected exception: " & Exception_Information (E));
   end On_Run;

   -------------------
   -- On_Stop_Build --
   -------------------

   procedure On_Stop_Build
     (Object : Data_Type_Access;
      Action : Guint;
      Widget : Limited_Widget)
   is
      Top : constant Glide_Window := Glide_Window (Object);
   begin
      Top.Interrupted := True;
   end On_Stop_Build;

   ---------------
   -- On_Manual --
   ---------------

   procedure On_Manual
     (Object : Data_Type_Access;
      Action : Guint;
      Widget : Limited_Widget)
   is
      Top : constant Glide_Window := Glide_Window (Object);
   begin
      case Help_Context'Val (Action) is
         when Welcome_Help =>
            Open_Html (Top.Kernel,
              Top.Prefix_Directory.all & "/doc/html/glide-welcome.html");

         when GVD_Help =>
            Open_Html (Top.Kernel,
              Top.Prefix_Directory.all & "/doc/html/gvd.html");

         when GNAT_UG_Help =>
            Open_Html (Top.Kernel,
              Top.Prefix_Directory.all & "/doc/html/gnat_ug.html");

         when GNAT_RM_Help =>
            Open_Html (Top.Kernel,
              Top.Prefix_Directory.all & "/doc/html/gnat_rm.html");

         when ARM95_Help =>
            Open_Html (Top.Kernel,
              Top.Prefix_Directory.all & "/doc/html/arm95.html");

         when GDB_Help =>
            Open_Html (Top.Kernel,
              Top.Prefix_Directory.all & "/doc/html/gdb.html");

         when GCC_Help =>
            Open_Html (Top.Kernel,
              Top.Prefix_Directory.all & "/doc/html/gcc.html");
      end case;

   exception
      when E : others =>
         Trace (Me, "Unexpected exception: " & Exception_Information (E));
   end On_Manual;

   --------------------
   -- On_About_Glide --
   --------------------

   procedure On_About_Glide
     (Object : Data_Type_Access;
      Action : Guint;
      Widget : Limited_Widget)
   is
      Button : Message_Dialog_Buttons;
   begin
      Button := Message_Dialog
        (-"Glide 2" & ASCII.LF & ASCII.LF & "(c) 2001 ACT-Europe",
         Help_Msg =>
           (-"This is the About information box.") & ASCII.LF & ASCII.LF &
           (-"Click on the OK button to close this window."),
         Title => -"About...");

   exception
      when E : others =>
         Trace (Me, "Unexpected exception: " & Exception_Information (E));
   end On_About_Glide;

   ----------------------
   -- Glide_Menu_Items --
   ----------------------

   function Glide_Menu_Items return Gtk_Item_Factory_Entry_Access is
      File        : constant String := "/_" & (-"File")     & '/';
      Edit        : constant String := "/_" & (-"Edit")     & '/';
      Gotom       : constant String := "/_" & (-"Navigate") & '/';
      Project     : constant String := "/_" & (-"Project")  & '/';
      Build       : constant String := "/_" & (-"Build")    & '/';
      Tools       : constant String := "/_" & (-"Tools")    & '/';
      Debug       : constant String := "/_" & (-"Debug")    & '/';
      Data_Sub    : constant String := (-"Data")            & '/';
      Window      : constant String := "/_" & (-"Window");
      Help        : constant String := "/_" & (-"Help")     & '/';

   begin
      return new Gtk_Item_Factory_Entry_Array'
        (Gtk_New (File & (-"Close"), "", Stock_Close, On_Close'Access),
         Gtk_New (File & (-"Close All"), "", null),
         Gtk_New (File & (-"Save Desktop"), "", On_Save_Desktop'Access),
         Gtk_New (File & "sep3", Item_Type => Separator),
         Gtk_New (File & (-"Print"), "", Stock_Print, null),
         Gtk_New (File & "sep4", Item_Type => Separator),
         Gtk_New (File & (-"Exit"), "<control>Q",
                  Stock_Quit, On_Exit'Access),

         Gtk_New (Edit & (-"Preferences"), "",
                  Stock_Preferences, On_Preferences'Access),

         Gtk_New (Gotom & (-"Goto Line..."), "", Stock_Jump_To, null),
         Gtk_New (Gotom & (-"Goto Body"), "", "", null),
         Gtk_New (Gotom & (-"Goto File Spec<->Body"), "", Stock_Convert, null),
         Gtk_New (Gotom & (-"Goto Previous Reference"), "", Stock_Undo, null),
         Gtk_New (Gotom & (-"Goto Parent Unit"), "", Stock_Go_Up, null),
         Gtk_New (Gotom & (-"List References"), "", Stock_Index, null),
         Gtk_New (Gotom & "sep1", Item_Type => Separator),
         Gtk_New (Gotom & (-"Start Of Statement"), "", Stock_Go_Up, null),
         Gtk_New (Gotom & (-"End Of Statement"), "", Stock_Go_Down, null),
         Gtk_New (Gotom & (-"Next Procedure"), "", Stock_Go_Forward, null),
         Gtk_New (Gotom & (-"Previous Procedure"), "", Stock_Go_Back, null),

         Gtk_New (Project & (-"Open..."), "", Stock_Open,
                  On_Open_Project'Access),
         Gtk_New (Project & "sep1", Item_Type => Separator),
         Gtk_New (Project & (-"Generate API doc"), "", Stock_Execute, null),

         Gtk_New (Build & (-"Check File"), "", null),
         Gtk_New (Build & (-"Compile File"), "", Stock_Convert, null),
         Gtk_New (Build & (-"Make"), "", Stock_Refresh, On_Build'Access),
         Gtk_New (Build & (-"Build Library"), "", null),
         Gtk_New (Build & "sep1", Item_Type => Separator),
         Gtk_New (Build & (-"Execute..."), "", Stock_Execute, On_Run'Access),
         Gtk_New (Build & "sep2", Item_Type => Separator),
         Gtk_New
           (Build & (-"Stop Build"), "", Stock_Stop, On_Stop_Build'Access),

         Gtk_New (Debug & Data_Sub & (-"Call Stack"), "", null, Check_Item),

         Gtk_New (Tools & (-"Call Graph"), "", null),
         Gtk_New (Tools & (-"Code Fixing"), "", null),
         Gtk_New (Tools & (-"Profile"), "", null),
         Gtk_New (Tools & (-"Memory Analyzer"), "", null),

         Gtk_New (Window),

         Gtk_New (Help & (-"Welcome"),
                  Callback => On_Manual'Access,
                  Callback_Action => Help_Context'Pos (Welcome_Help)),
         Gtk_New (Help & (-"Using the GNU Visual Debugger"), "",
                  Callback => On_Manual'Access,
                  Callback_Action => Help_Context'Pos (GVD_Help)),
         Gtk_New (Help & (-"GNAT User's Guide"), "",
                  Callback => On_Manual'Access,
                  Callback_Action => Help_Context'Pos (GNAT_UG_Help)),
         Gtk_New (Help & (-"GNAT Reference Manual"), "",
                  Callback => On_Manual'Access,
                  Callback_Action => Help_Context'Pos (GNAT_RM_Help)),
         Gtk_New (Help & (-"Ada 95 Reference Manual"), "",
                  Callback => On_Manual'Access,
                  Callback_Action => Help_Context'Pos (ARM95_Help)),
         Gtk_New (Help & (-"Using the GNU Debugger"), "",
                  Callback => On_Manual'Access,
                  Callback_Action => Help_Context'Pos (GDB_Help)),
         Gtk_New (Help & (-"Using GCC"), "",
                  Callback => On_Manual'Access,
                  Callback_Action => Help_Context'Pos (GCC_Help)),
         Gtk_New (Help & (-"About Glide"), "", On_About_Glide'Access));
   end Glide_Menu_Items;

end Glide_Menu;
