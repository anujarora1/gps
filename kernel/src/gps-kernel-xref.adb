------------------------------------------------------------------------------
--                                  G P S                                   --
--                                                                          --
--                     Copyright (C) 2012-2014, AdaCore                     --
--                                                                          --
-- This is free software;  you can redistribute it  and/or modify it  under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

with Ada.Containers.Indefinite_Holders;
with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with Commands.Generic_Asynchronous;  use Commands;
with Commands;                       use Commands;
with GNATCOLL.SQL.Exec;              use GNATCOLL.SQL.Exec;
with GNATCOLL.Traces;                use GNATCOLL.Traces;
with GNATCOLL.Utils;
with GPS.Intl;                       use GPS.Intl;
with GPS.Kernel.Contexts;            use GPS.Kernel.Contexts;
with GPS.Kernel.MDI;                 use GPS.Kernel.MDI;
with GPS.Kernel.Preferences;         use GPS.Kernel.Preferences;
with GPS.Kernel.Project;             use GPS.Kernel.Project;
with GPS.Kernel.Task_Manager;        use GPS.Kernel.Task_Manager;
with GPS.Kernel;                     use GPS.Kernel;
with Glib.Convert;                   use Glib.Convert;
with Glib.Object;                    use Glib.Object;
with GUI_Utils;                      use GUI_Utils;
with Gtk.Box;                        use Gtk.Box;
with Gtk.Dialog;                     use Gtk.Dialog;
with Gtk.Enums;                      use Gtk.Enums;
with Gtk.Scrolled_Window;            use Gtk.Scrolled_Window;
with Gtk.Stock;                      use Gtk.Stock;
with Gtk.Label;                      use Gtk.Label;
with Gtk.Tree_Model;                 use Gtk.Tree_Model;
with Gtk.Tree_Selection;             use Gtk.Tree_Selection;
with Gtk.Tree_Store;                 use Gtk.Tree_Store;
with Gtk.Tree_View;                  use Gtk.Tree_View;
with Gtk.Widget;                     use Gtk.Widget;
with Gtkada.Handlers;                use Gtkada.Handlers;
with Old_Entities.Queries;
with Old_Entities.Values;
with System;                         use System;

package body GPS.Kernel.Xref is
   use Xref;

   package Holder is new Ada.Containers.Indefinite_Holders (Root_Entity'Class);

   Me : constant Trace_Handle := Create ("Xref");

   type All_LI_Information_Command (Name_Len : Natural)
   is new Root_Command with record
      Iter         : Old_Entities.Queries.Recursive_LI_Information_Iterator;
      Lang_Name    : String (1 .. Name_Len);
      Count, Total : Natural := 0;
      Chunk_Size   : Natural := 10;  --  ??? Should be configurable
   end record;

   overriding function Progress
     (Command : access All_LI_Information_Command) return Progress_Record;
   overriding function Execute
     (Command : access All_LI_Information_Command) return Command_Return_Type;
   overriding function Name
     (Command : access All_LI_Information_Command) return String;

   function C_Filter (Ext : Filesystem_String) return Boolean;
   --  Return true if Lang is C or C++ (case insensitive)

   type Examine_Callback is record
      Iter              : Standard.Xref.Entity_Reference_Iterator;
      Kernel            : Kernel_Handle;
      Entity            : Holder.Holder;
      Data              : Commands_User_Data;
      Watch             : Gtk_Widget;
      Dispatching_Calls : Boolean;
      Cancelled         : Boolean;
   end record;
   type Examine_Callback_Access is access Examine_Callback;

   procedure Unchecked_Free is new Ada.Unchecked_Deallocation
     (Commands_User_Data_Record'Class, Commands_User_Data);
   procedure Unchecked_Free is new Ada.Unchecked_Deallocation
     (Examine_Callback, Examine_Callback_Access);
   function Convert is new Ada.Unchecked_Conversion
     (System.Address, Examine_Callback_Access);

   procedure Destroy_Idle (Data : in out Examine_Callback_Access);
   --  Called when the idle loop is destroyed.

   package Ancestor_Commands is new Generic_Asynchronous
     (Examine_Callback_Access, Destroy_Idle);

   procedure Examine_Ancestors_Idle
     (Data    : in out Examine_Callback_Access;
      Command : Command_Access;
      Result  : out Command_Return_Type);
   --  Called for every occurrence of Data.Entity

   procedure Watch_Destroyed_While_Computing
     (Data : System.Address; Object : System.Address);
   pragma Convention (C, Watch_Destroyed_While_Computing);

   procedure Row_Activated (Widget : access Gtk_Widget_Record'Class);
   --  Called when a specific entity declaration has been selected in the
   --  overloaded entities dialog.

   type SQL_Error_Reporter is new GNATCOLL.SQL.Exec.Error_Reporter with record
      Kernel : access Kernel_Handle_Record'Class;

      Warned_About_Corruption : Boolean := False;
      --  Used to avoid duplicate messages about corrupted database
   end record;
   overriding procedure On_Database_Corrupted
     (Self       : in out SQL_Error_Reporter;
      Connection : access Database_Connection_Record'Class);

   ----------
   -- Name --
   ----------

   overriding function Name
     (Command : access All_LI_Information_Command) return String is
   begin
      return Command.Lang_Name;
   end Name;

   --------------
   -- Progress --
   --------------

   overriding function Progress
     (Command : access All_LI_Information_Command) return Progress_Record is
   begin
      return Progress_Record'
        (Activity => Running,
         Current  => Command.Count,
         Total    => Command.Total);
   end Progress;

   -------------
   -- Execute --
   -------------

   overriding function Execute
     (Command : access All_LI_Information_Command) return Command_Return_Type
   is
   begin
      Old_Entities.Queries.Next (Command.Iter, Steps => Command.Chunk_Size,
            Count => Command.Count, Total => Command.Total);

      if Command.Count >= Command.Total then
         Trace (Me, "Finished loading xref in memory");
         Old_Entities.Queries.Free (Command.Iter);
         return Success;
      else
         if Active (Me) then
            Trace (Me, "Load xref in memory, count="
                   & Command.Count'Img & " total="
                   & Command.Total'Img);
         end if;
         return Execute_Again;
      end if;
   end Execute;

   --------------
   -- On_Error --
   --------------

   overriding procedure On_Error
     (Self  : GPS_Xref_Database;
      Error : String)
   is
   begin
      Self.Kernel.Insert
        (Text   => Error,
         Add_LF => True,
         Mode   => GPS.Kernel.Error);
   end On_Error;

   -------------------------------
   -- Ensure_Context_Up_To_Date --
   -------------------------------

   procedure Ensure_Context_Up_To_Date (Context : Selection_Context) is
      use Old_Entities;
      Kernel : constant Kernel_Handle := Get_Kernel (Context);
   begin
      if not Active (Standard.Xref.SQLITE)
        and then Has_Entity_Name_Information (Context)
        and then Has_Line_Information (Context)
        and then Has_File_Information (Context)
      then
         declare
            Handler : Old_Entities.LI_Handler;
            File    : Old_Entities.Source_File;

         begin
            File :=
              Old_Entities.Get_Or_Create
                (Db   => Kernel.Databases.Entities,
                 File => File_Information (Context));

            Handler := Old_Entities.Get_LI_Handler
              (Kernel.Databases.Entities);

            if Old_Entities.Has_Unresolved_Imported_Refs
              (Old_Entities.Get_LI (File))
            then
               Old_Entities.Set_Update_Forced (Handler);
               Old_Entities.Update_Xref (File);
            end if;
         end;
      end if;
   end Ensure_Context_Up_To_Date;

   --------------
   -- C_Filter --
   --------------

   function C_Filter (Ext : Filesystem_String) return Boolean is
   begin
      return Ext = ".gli";
   end C_Filter;

   -------------------------
   -- Load_Xref_In_Memory --
   -------------------------

   procedure Load_Xref_In_Memory
     (Kernel       : access Kernel_Handle_Record'Class;
      C_Only       : Boolean)
   is
      use Old_Entities;
      C : Command_Access;
      C_Name : constant String := "load C/C++ xref";
      All_Name : constant String := "load xref";

   begin
      if Active (Standard.Xref.SQLITE) then
         --  Nothing to do
         return;
      end if;

      if Active (Me) then
         Trace (Me, "Load xref in memory, c only ? " & C_Only'Img);
      end if;

      if C_Only then
         C := new All_LI_Information_Command
           (Name_Len => C_Name'Length);
         All_LI_Information_Command (C.all).Lang_Name := C_Name;

         Old_Entities.Queries.Start
           (All_LI_Information_Command (C.all).Iter,
            Kernel.Databases.Entities,
            Get_Language_Handler (Kernel),
            Get_Project (Kernel).Start (Recursive => True),
            C_Filter'Access);
      else
         C := new All_LI_Information_Command
           (Name_Len => All_Name'Length);
         All_LI_Information_Command (C.all).Lang_Name := All_Name;
         Old_Entities.Queries.Start
           (All_LI_Information_Command (C.all).Iter,
            Kernel.Databases.Entities,
            Get_Language_Handler (Kernel),
            Get_Project (Kernel).Start (Recursive => True));
      end if;

      GPS.Kernel.Task_Manager.Launch_Background_Command
        (Kernel,
         C,
         Active     => True,
         Show_Bar   => True,
         Queue_Id   => All_LI_Information_Command (C.all).Lang_Name,
         Block_Exit => False);
   end Load_Xref_In_Memory;

   -------------------------------------
   -- Watch_Destroyed_While_Computing --
   -------------------------------------

   procedure Watch_Destroyed_While_Computing
     (Data : System.Address; Object : System.Address)
   is
      pragma Unreferenced (Object);
   begin
      Convert (Data).Cancelled := True;
   end Watch_Destroyed_While_Computing;

   ------------------
   -- Destroy_Idle --
   ------------------

   procedure Destroy_Idle (Data : in out Examine_Callback_Access) is
      V : Root_Entity'Class := Data.Entity.Element;
   begin
      if not Data.Cancelled
        and then Data.Watch /= null
      then
         Weak_Unref (Data.Watch, Watch_Destroyed_While_Computing'Access,
                     Data.all'Address);
      end if;

      Destroy (Data.Data.all, Data.Cancelled);
      Unchecked_Free (Data.Data);
      Destroy (Data.Iter);
      Unref (V);
      Unchecked_Free (Data);
   end Destroy_Idle;

   -------------
   -- Destroy --
   -------------

   procedure Destroy
     (Data : in out Commands_User_Data_Record; Cancelled : Boolean)
   is
      pragma Unreferenced (Data, Cancelled);
   begin
      null;
   end Destroy;

   ----------------------------
   -- Examine_Ancestors_Idle --
   ----------------------------

   ----------------------------
   -- Examine_Ancestors_Idle --
   ----------------------------

   procedure Examine_Ancestors_Idle
     (Data    : in out Examine_Callback_Access;
      Command : Command_Access;
      Result  : out Command_Return_Type)
   is
      Ref    : General_Entity_Reference;
   begin
      if Data.Cancelled then
         Result := Failure;

      elsif At_End (Data.Iter) then
         Result := Success;

      else
         Ref := Get (Data.Iter);
         Result := Execute_Again;

         if Ref /= No_General_Entity_Reference
           and then not Data.Kernel.Databases.Reference_Is_Declaration (Ref)
         then
            declare
               Parent : Root_Entity'Class := Get_Caller (Ref);
            begin
               if Parent /= No_Root_Entity
                 and then Data.Kernel.Databases.Show_In_Callgraph (Ref)
               then
                  while Parent /= No_Root_Entity
                    and then not Is_Container (Parent)
                  loop
                     Parent := Caller_At_Declaration (Parent);
                  end loop;

                  if Parent /= No_Root_Entity then
                     --  If we are seeing a dispatching call to an overridden
                     --  subprogram, this could also result in a call to the
                     --  entity and we report it

                     if Get_Entity (Data.Iter) /= Data.Entity.Element then
                        if Data.Kernel.Databases.Is_Dispatching_Call (Ref) then
                           if not On_Entity_Found
                             (Data.Data, Get_Entity (Data.Iter), Parent, Ref,
                              Through_Dispatching => True,
                              Is_Renaming         => False)
                           then
                              Result := Failure;
                           end if;
                        end if;

                     else
                        if not On_Entity_Found
                          (Data.Data, Data.Entity.Element, Parent, Ref,
                           Through_Dispatching    => False,
                           Is_Renaming            => False)
                        then
                           Result := Failure;
                        end if;
                     end if;
                  end if;
               end if;
            end;
         end if;

         Next (Data.Iter);

         if Command /= null then
            Set_Progress
              (Command,
               (Running,
                Get_Current_Progress (Data.Iter),
                Get_Total_Progress (Data.Iter)));
         end if;
      end if;

   exception
      when E : others =>
         Trace (Me, E);
         Result := Failure;
   end Examine_Ancestors_Idle;

   ----------------------------------
   -- Examine_Ancestors_Call_Graph --
   ----------------------------------

   procedure Examine_Ancestors_Call_Graph
     (Kernel            : access Kernel_Handle_Record'Class;
      Entity            : Root_Entity'Class;
      User_Data         : access Commands_User_Data_Record'Class;
      Background_Mode   : Boolean := True;
      Dispatching_Calls : Boolean := False;
      Watch             : Gtk.Widget.Gtk_Widget := null)
   is
      Cb     : Examine_Callback_Access;
      C      : Ancestor_Commands.Generic_Asynchronous_Command_Access;
      Result : Command_Return_Type;
      H      : Holder.Holder;
   begin
      H.Replace_Element (Entity);
      Cb := new Examine_Callback'
        (Kernel            => Kernel_Handle (Kernel),
         Data              => Commands_User_Data (User_Data),
         Entity            => H,
         Watch             => Watch,
         Cancelled         => False,
         Dispatching_Calls => Dispatching_Calls,
         Iter              => <>);
      Ref (Entity);

      --  If we have a renaming, report it

      declare
         Rename : constant Root_Entity'Class := Entity.Renaming_Of;
      begin
         if Rename /= No_Root_Entity then
            if not On_Entity_Found
              (User_Data, Entity, Rename, No_General_Entity_Reference,
               Through_Dispatching => False,
               Is_Renaming         => True)
            then
               Destroy_Idle (Cb);
               return;
            end if;
         end if;
      end;

      Find_All_References
        (Iter               => Cb.Iter,
         Entity             => Entity,
         Include_Overridden => Dispatching_Calls);

      if Watch /= null then
         Weak_Ref
           (Watch,
            Watch_Destroyed_While_Computing'Access,
            Cb.all'Address);
      end if;

      if Background_Mode then
         Ancestor_Commands.Create
           (C, -"Called by", Cb, Examine_Ancestors_Idle'Access);
         Launch_Background_Command
           (Kernel, Command_Access (C), True, True, "call graph");
      else
         loop
            Examine_Ancestors_Idle (Cb, Command_Access (C), Result);
            exit when Result /= Execute_Again;
         end loop;
         Destroy_Idle (Cb);
      end if;
   end Examine_Ancestors_Call_Graph;

   -------------------------------
   -- Examine_Entity_Call_Graph --
   -------------------------------

   procedure Examine_Entity_Call_Graph
     (Kernel            : access GPS.Kernel.Kernel_Handle_Record'Class;
      Entity            : Root_Entity'Class;
      User_Data         : access Commands_User_Data_Record'Class;
      Get_All_Refs      : Boolean;
      Dispatching_Calls : Boolean)
   is
      Calls       : Calls_Iterator;
      Called_E_Decl : General_Location;
      Refs        : Standard.Xref.Entity_Reference_Iterator;
      Ref         : General_Entity_Reference;
      Data        : Commands_User_Data;
      Is_First    : Boolean;
      Through_Dispatching : Boolean;
   begin
      if Entity /= No_Root_Entity then
         declare
            Calls : Calls_Iterator'Class := Get_All_Called_Entities (Entity);
         begin
            For_Each_Entity :
            while not At_End (Calls) loop
               declare
                  Called_E : constant Root_Entity'Class := Get (Calls);
               begin
                  if Called_E /= No_Root_Entity
                    and then Called_E.Is_Subprogram
                  then
                     Called_E_Decl := Called_E.Get_Declaration.Loc;

                     if Get_All_Refs or Dispatching_Calls then
                        --  Now search for all references. This was either
                        --  requested explicitly or is needed to resolve
                        --  dispatching calls

                        Find_All_References
                          (Iter     => Refs,
                           Entity   => Called_E,
                           In_Scope => Entity);
                        Is_First := True;

                        while not At_End (Refs) loop
                           Ref := Get (Refs);
                           if Ref /= No_General_Entity_Reference
                             and then Kernel.Databases.Show_In_Callgraph (Ref)
                             and then Get_Caller (Ref) = Entity
                             and then Get_Entity (Refs).Is_Subprogram
                               and then Called_E_Decl /= Get_Location (Ref)
                           then
                              --  If we want to see all references, report this
                              --  one now, unless it is a dispatching call
                              --  which is already reported later on

                              if Get_All_Refs then
                                 Through_Dispatching :=
                                   Kernel.Databases.Is_Dispatching_Call (Ref);

                                 if not Dispatching_Calls
                                   or else not Through_Dispatching
                                 then
                                    if not On_Entity_Found
                                      (User_Data,
                                       Entity         => Get_Entity (Refs),
                                       Parent              => Entity,
                                       Ref                 => Ref,
                                       Through_Dispatching =>
                                         Through_Dispatching,
                                       Is_Renaming         => False)
                                    then
                                       exit For_Each_Entity;
                                    end if;
                                 end if;

                                 --  Else we only want to report the callee
                                 --  once, ie on its first reference. We still
                                 --  have to examine all references through to
                                 --  solve dispatching calls.

                              elsif Is_First
                                and then not Kernel.Databases.
                                  Is_Dispatching_Call (Ref)
                              then
                                 Is_First := False;
                                 if not On_Entity_Found
                                   (User_Data,
                                    Entity              => Get_Entity (Refs),
                                    Parent              => Entity,
                                    Ref                 =>
                                      No_General_Entity_Reference,
                                    Through_Dispatching => False,
                                    Is_Renaming         => False)
                                 then
                                    exit For_Each_Entity;
                                 end if;
                              end if;

                              --  Now if the reference is in fact a dispatching
                              --  call, report all called entities.

                              if Dispatching_Calls then
                                 declare
                                    Stop      : Boolean := False;
                                    function On_Callee
                                      (Callee : Root_Entity'Class)
                                       return Boolean;

                                    function On_Callee
                                      (Callee : Root_Entity'Class)
                                       return Boolean
                                    is
                                    begin
                                       if not On_Entity_Found
                                         (User_Data,
                                          Entity              => Callee,
                                          Parent              => Entity,
                                          Ref                 => Ref,
                                          Through_Dispatching => True,
                                          Is_Renaming         => False)
                                       then
                                          Stop := True;
                                          return False;
                                       end if;
                                       return True;
                                    end On_Callee;

                                 begin
                                    --  Always compute accurate information
                                    --  for the call graph, since, as opposed
                                    --  to the contextual menu, we have more
                                    --  time to do the computation
                                    Increase_Indent
                                      (Me,
                                       "Searching for all dispatch calls at "
                                       & Get_Location (Ref).Line'Img);

                                    For_Each_Dispatching_Call
                                      (Entity    => Get_Entity (Refs),
                                       Ref       => Ref,
                                       Filter    =>
                                         Reference_Is_Declaration'Access,
                                       On_Callee => On_Callee'Access);
                                    Decrease_Indent (Me);
                                    exit For_Each_Entity when Stop;
                                 end;
                              end if;
                           end if;

                           Next (Refs);
                        end loop;
                        Destroy (Refs);
                     else
                        if not On_Entity_Found
                          (User_Data,
                           Entity              => Called_E,
                           Parent              => Entity,
                           Ref                 => No_General_Entity_Reference,
                           Through_Dispatching => False,
                           Is_Renaming         => False)
                        then
                           exit For_Each_Entity;
                        end if;
                     end if;
                  end if;

                  Next (Calls);
               end;
            end loop For_Each_Entity;
         end;

         Destroy (Calls);

         Destroy (User_Data.all, Cancelled => False);
         Data := Commands_User_Data (User_Data);
         Unchecked_Free (Data);
      end if;
   end Examine_Entity_Call_Graph;

   ---------------------------------
   -- Get_Entity_Information_Type --
   ---------------------------------

   function Get_Entity_Information_Type return Glib.GType is
   begin
      if Active (SQLITE) then
         return Glib.GType_Int;
      else
         return Old_Entities.Values.Get_Entity_Information_Type;
      end if;
   end Get_Entity_Information_Type;

   ---------------------------
   -- On_Database_Corrupted --
   ---------------------------

   overriding procedure On_Database_Corrupted
     (Self       : in out SQL_Error_Reporter;
      Connection : access Database_Connection_Record'Class)
   is
      pragma Unreferenced (Connection);
   begin
      if not Self.Warned_About_Corruption then
         Self.Warned_About_Corruption := True;
         Insert
           (Self.Kernel,
            "Cross-reference database appears to be corrupted." & ASCII.LF
            & "Please exit GPS, delete the file '"
            & Xref_Database_Location (Self.Kernel.Databases).Display_Full_Name
            & "' and restart GPS",
            Mode => Error);
      end if;
   end On_Database_Corrupted;

   ---------------------
   -- Create_Database --
   ---------------------

   procedure Create_Database
     (Kernel : access GPS.Kernel.Kernel_Handle_Record'Class;
      Result : out Standard.Xref.General_Xref_Database)
   is
      Errors : access SQL_Error_Reporter'Class;
   begin
      if Kernel.Databases = null then
         Result := new GPS_General_Xref_Database_Record;
         GPS_General_Xref_Database_Record (Result.all).Kernel :=
           Kernel_Handle (Kernel);
      else
         Result := Kernel.Databases;
      end if;

      if Active (SQLITE) then
         if Result.Xref = null then
            Result.Xref := new GPS.Kernel.Xref.GPS_Xref_Database;
            GPS_Xref_Database (Result.Xref.all).Kernel :=
              Kernel_Handle (Kernel);
         end if;
      end if;

      Errors := new SQL_Error_Reporter;   --  never freed
      Errors.Kernel := Kernel;

      Result.Initialize
        (Lang_Handler => Kernel.Lang_Handler,
         Symbols      => Kernel.Symbols,
         Registry     => Kernel.Registry,
         Errors       => Errors,
         Subprogram_Ref_Is_Call =>
            not Require_GNAT_Date
              (Kernel, Old_Entities.Advanced_Ref_In_Call_Graph_Date));
   end Create_Database;

   --------------------------
   -- Compilation_Finished --
   --------------------------

   procedure Compilation_Finished
     (Kernel : access Kernel_Handle_Record'Class;
      C_Only : Boolean)
   is
   begin
      Trace (Me, "Compilation finished, loading xref");
      if Active (SQLITE) then
         --  Nothing to do: the plugin cross_references.py has a special
         --  target that already takes care of re-running gnatinspect when a
         --  compilation is finished.
         null;

      else
         Load_Xref_In_Memory (Kernel, C_Only => C_Only);

      end if;
   end Compilation_Finished;

   ------------------------------
   -- Parse_All_LI_Information --
   ------------------------------

   procedure Parse_All_LI_Information
     (Kernel    : access Kernel_Handle_Record'Class;
      Project   : Project_Type;
      Recursive : Boolean)
   is
   begin
      if not Active (SQLITE) then
         declare
            use Old_Entities, Old_Entities.Queries;
            Iter : Recursive_LI_Information_Iterator;
            Count, Total : Natural;
         begin
            Start (Iter,
                   Kernel.Databases.Entities,
                   Get_Language_Handler (Kernel),
                   Project => Project.Start (Recursive => Recursive));

            loop
               Next (Iter, Steps => Natural'Last,  --  As much as possible
                     Count => Count, Total => Total);
               exit when Count >= Total;
            end loop;

            Free (Iter);
         end;
      end if;
   end Parse_All_LI_Information;

   -------------------------------
   -- Select_Entity_Declaration --
   -------------------------------

   overriding function Select_Entity_Declaration
     (Self    : access GPS_General_Xref_Database_Record;
      File    : Virtual_File;
      Project : Project_Type;
      Entity  : Root_Entity'Class) return Root_Entity'Class
   is
      procedure Set
        (Tree : System.Address;
         Iter : Gtk_Tree_Iter;
         Col1 : Gint := 0; Value1 : String;
         Col2 : Gint := 1; Value2 : Gint;
         Col3 : Gint := 2; Value3 : Gint);
      pragma Import (C, Set, "ada_gtk_tree_store_set_ptr_int_int");

      Column_Types : constant GType_Array :=
        (0 => GType_String,
         1 => GType_Int,
         2 => GType_Int,
         3 => GType_String,
         4 => GType_Int);  --  Contains the number of the iter
      Column_Names : GNAT.Strings.String_List :=
        (1 => new String'("File"),
         2 => new String'("Line"),
         3 => new String'("Column"),
         4 => new String'("Name"));

      Name : constant String := Entity.Get_Name;

      Iter      : Entities_In_File_Cursor;
      Button    : Gtk_Widget;
      OK_Button : Gtk_Widget;
      Count     : Natural := 0;
      Label     : Gtk_Label;
      Model     : Gtk_Tree_Store;
      M         : Gtk_Tree_Model;
      Dialog    : Gtk_Dialog;
      It        : Gtk_Tree_Iter;
      Scrolled  : Gtk_Scrolled_Window;
      View      : Gtk_Tree_View;
      Col_Num   : Gint;
--        Val       : Glib.Values.GValue;
      Candidate_Decl : General_Entity_Declaration;
--        Result    : Root_Entity'Class;
      pragma Unreferenced (Button, Col_Num);

      Number_Selected : Natural := 0;
   begin
      Iter := Self.Entities_In_File
        (File    => File,
         Project => Project,
         Name    => Name);

      while not At_End (Iter) loop
         Count := Count + 1;
         declare
            Candidate : constant Root_Entity'Class := Get (Iter);
         begin
            Candidate_Decl := Candidate.Get_Declaration;

            if Count = 1 then
               Gtk_New (Dialog,
                        Title  => -"Select the declaration",
                        Parent => Get_Main_Window (Self.Kernel),
                        Flags  => Modal or Destroy_With_Parent);
               Set_Default_Size (Dialog, 500, 500);

               Gtk_New (Label, -"This entity is overloaded.");
               Pack_Start (Dialog.Get_Action_Area, Label, Expand => False);

               Gtk_New (Label, -"Please select the appropriate declaration.");
               Pack_Start (Dialog.Get_Action_Area, Label, Expand => False);

               Gtk_New (Scrolled);
               Set_Policy (Scrolled, Policy_Automatic, Policy_Automatic);
               Pack_Start (Dialog.Get_Action_Area, Scrolled);

               OK_Button := Add_Button (Dialog, Stock_Ok, Gtk_Response_OK);
               Button := Add_Button
                 (Dialog, Stock_Cancel, Gtk_Response_Cancel);

               View := Create_Tree_View
                 (Column_Types       => Column_Types,
                  Column_Names       => Column_Names,
                  Initial_Sort_On    => 1);
               Add (Scrolled, View);
               Model := -Get_Model (View);

               Widget_Callback.Object_Connect
                 (View, Signal_Row_Activated, Row_Activated'Access, Dialog);
            end if;

            Append (Model, It, Null_Iter);
            Set (Get_Object (Model), It,
                 0, +Candidate_Decl.Loc.File.Base_Name & ASCII.NUL,
                 1, Gint (Candidate_Decl.Loc.Line),
                 2, Gint (Candidate_Decl.Loc.Column));
            Set (Model, It, 3, Candidate.Get_Name & ASCII.NUL);
            Set (Model, It, 4, Gint (Count));

            if Candidate = Entity then
               Select_Iter (Get_Selection (View), It);
            end if;
         end;

         Next (Iter);
      end loop;

      if Count > 0 then
         Grab_Default (OK_Button);
         Grab_Toplevel_Focus (Get_MDI (Self.Kernel), OK_Button);
         Show_All (Dialog);

         if Run (Dialog) = Gtk_Response_OK then
            Get_Selected (Get_Selection (View), M, It);
            Number_Selected := Natural (Get_Int (M, It, 4));

            Iter := Self.Entities_In_File
              (File    => File,
               Project => Project,
               Name    => Name);

            Count := 0;

            while not At_End (Iter) loop
               Count := Count + 1;
               if Count = Number_Selected then
                  declare
                     Result : constant Root_Entity'Class := Get (Iter);
                  begin
                     Destroy (Dialog);
                     GNATCOLL.Utils.Free (Column_Names);
                     return Result;
                  end;
               end if;
               Next (Iter);
            end loop;
         end if;

         Destroy (Dialog);
      end if;

      GNATCOLL.Utils.Free (Column_Names);

      return No_Root_Entity;

   exception
      when E : others =>
         Trace (Me, E);

         if Dialog /= null then
            Destroy (Dialog);
         end if;

         raise;
   end Select_Entity_Declaration;

   -------------------
   -- Row_Activated --
   -------------------

   procedure Row_Activated (Widget : access Gtk_Widget_Record'Class) is
   begin
      Response (Gtk_Dialog (Widget), Gtk_Response_OK);
   end Row_Activated;

   -------------------
   -- Add_Parameter --
   -------------------

   overriding procedure Add_Parameter
     (Self    : access HTML_Profile_Formater;
      Name    : String;
      Mode    : String;
      Of_Type : String;
      Default : String)
   is
      use Ada.Strings.Unbounded;
   begin
      if Self.Has_Parameter then
         Append (Self.Text, ASCII.LF & " ");
      else
         Append (Self.Text, "<b>Parameters:</b>" & ASCII.LF & " ");
         Self.Has_Parameter := True;
      end if;

      if Default = "" then
         --  Keep the parameters aligned, in case some are
         --  optional and start with '['
         Append (Self.Text, " ");
      else
         Append (Self.Text, "<span foreground=""");
         Append (Self.Text, Self.Color_For_Optional_Param);
         Append (Self.Text, """>[");
      end if;

      Append (Self.Text, Escape_Text (Name));
      Append (Self.Text, " : <b>");
      Append (Self.Text, Mode);
      Append (Self.Text, "</b>");
      Append (Self.Text, Escape_Text (Of_Type));

      if Default /= "" then
         Append (Self.Text, " :=");
         Append (Self.Text, Escape_Text (Default));
         Append (Self.Text, "]</span>");
      end if;
   end Add_Parameter;

   ----------------
   -- Add_Result --
   ----------------

   overriding procedure Add_Result
     (Self    : access HTML_Profile_Formater;
      Mode    : String;
      Of_Type : String)
   is
      use Ada.Strings.Unbounded;
   begin
      if Self.Has_Parameter then
         Append (Self.Text, ASCII.LF);
         Self.Has_Parameter := False;
      end if;
      Append (Self.Text, "<b>Return:</b>" & ASCII.LF & " <b>");
      Append (Self.Text, Mode);
      Append (Self.Text, "</b>");
      Append (Self.Text, Escape_Text (Of_Type));
   end Add_Result;

   ------------------
   -- Add_Variable --
   ------------------

   overriding procedure Add_Variable
     (Self    : access HTML_Profile_Formater;
      Mode    : String;
      Of_Type : String)
   is
      use Ada.Strings.Unbounded;
   begin
      Append (Self.Text, "<b>Type: ");
      Append (Self.Text, Mode);
      Append (Self.Text, "</b>");
      Append (Self.Text, Escape_Text (Of_Type));
   end Add_Variable;

   -----------------
   -- Add_Aspects --
   -----------------

   overriding procedure Add_Aspects
     (Self : access HTML_Profile_Formater;
      Text : String)
   is
      use Ada.Strings.Unbounded;
   begin
      if Self.Has_Parameter then
         Append (Self.Text, ASCII.LF);
         Self.Has_Parameter := False;
      end if;
      Append (Self.Text, ASCII.LF & "<b>Aspects:</b>" & ASCII.LF);
      Append (Self.Text, Escape_Text (Text));
   end Add_Aspects;

   ------------------
   -- Add_Comments --
   ------------------

   overriding procedure Add_Comments
     (Self : access HTML_Profile_Formater;
      Text : String)
   is
      use Ada.Strings.Unbounded;
   begin
      if Self.Has_Parameter then
         Append (Self.Text, ASCII.LF);
         Self.Has_Parameter := False;
      end if;
      if Length (Self.Text) = 0 then
         Append (Self.Text, Escape_Text (Text));
      else
         Self.Text := Escape_Text (Text) & ASCII.LF & ASCII.LF & Self.Text;
      end if;
   end Add_Comments;

   --------------
   -- Get_Text --
   --------------

   overriding function Get_Text
     (Self : access HTML_Profile_Formater) return String
   is
      use Ada.Strings.Unbounded;
   begin
      if Self.Has_Parameter then
         Append (Self.Text, ASCII.LF);
         Self.Has_Parameter := False;
      end if;

      return To_String (Self.Text);
   end Get_Text;

   -------------------
   -- Documentation --
   -------------------

   function Documentation
     (Self             : General_Xref_Database;
      Handler          : Language_Handlers.Language_Handler;
      Entity           : Root_Entity'Class;
      Color_For_Optional_Param : String := "#555555";
      Raw_Format       : Boolean := False;
      Check_Constructs : Boolean := True) return String
   is
      pragma Unreferenced (Self);
      use Ada.Strings.Unbounded;
   begin
      if Raw_Format then
         declare
            Formater : aliased Text_Profile_Formater;
         begin
            Documentation
              (Handler           => Handler,
               Entity            => Entity,
               Formater          => Formater'Access,
               Check_Constructs  => Check_Constructs,
               Look_Before_First => Doc_Search_Before_First.Get_Pref);

            return Formater.Get_Text;
         end;
      else
         declare
            Formater : aliased HTML_Profile_Formater;
         begin
            Formater.Color_For_Optional_Param :=
              To_Unbounded_String (Color_For_Optional_Param);

            Documentation
              (Handler           => Handler,
               Entity            => Entity,
               Formater          => Formater'Access,
               Check_Constructs  => Check_Constructs,
               Look_Before_First => Doc_Search_Before_First.Get_Pref);

            return Formater.Get_Text;
         end;
      end if;
   end Documentation;

end GPS.Kernel.Xref;
