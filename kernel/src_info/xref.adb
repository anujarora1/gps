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

with Ada.Containers.Doubly_Linked_Lists;
with Ada.Containers;            use Ada.Containers;
with Ada.Exceptions;            use Ada.Exceptions;
with Ada.Strings.Maps;          use Ada.Strings.Maps;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;
with ALI_Parser;
with GNATCOLL.Projects;         use GNATCOLL.Projects;
with GNATCOLL.SQL.Sqlite;
with GNATCOLL.Symbols;          use GNATCOLL.Symbols;
with GNATCOLL.Utils;            use GNATCOLL.Utils;
with GNAT.OS_Lib;
with GNAT.SHA1;                 use GNAT.SHA1;
with GNAT.Strings;              use GNAT.Strings;
with Language_Handlers;         use Language_Handlers;
with Language.Tree;             use Language.Tree;
with Language.Tree.Database;    use Language.Tree.Database;
with String_Utils;
with Language; use Language;

package body Xref is
   Me : constant Trace_Handle := Create ("Xref");
   Constructs_Heuristics : constant Trace_Handle :=
     Create ("Entities.Constructs", On);

   ---------------------------
   --  Note for development --
   ---------------------------

   --  A lot of functions defined here use either the new system
   --  (GNATCOLL.Xref) or the legacy database (Entities.*), and
   --  sometimes fallback on the constructs database.

   use type Old_Entities.Entity_Information;
   use type Old_Entities.File_Location;

   type Hash_Type is range 0 .. 2 ** 20 - 1;
   function Hash is new String_Utils.Hash (Hash_Type);

   package Entity_Lists is new Ada.Containers.Doubly_Linked_Lists
      (General_Entity);
   use Entity_Lists;

   function Get_Location
     (Ref : Entity_Reference) return General_Location;
   --  Return the General Location of a GNATCOLL reference

   procedure Node_From_Entity
     (Self        : access General_Xref_Database_Record'Class;
      Handler     : access Abstract_Language_Handler_Record'Class;
      Decl        : General_Location;
      Ent         : out Entity_Access;
      Tree_Lang   : out Tree_Language_Access;
      Name        : String := "");
   --  Returns the constructs data for a given entity. Name is optional. If it
   --  is given, this will perform a search by name in the construct database.
   --  If the result is unique, then it will return it.

   function Construct_From_Entity
     (Self : access General_Xref_Database_Record'Class;
      Entity : General_Entity) return access Simple_Construct_Information;
   --  Returns Construct_Information from an Entity. This access shouldn't be
   --  kept because it will be invalid next time the constructs database is
   --  updated

   function To_String (Loc : General_Location) return String;
   --  Display Loc

   function To_General_Entity
     (E : Old_Entities.Entity_Information) return General_Entity;
   function To_General_Entity
     (Db : access General_Xref_Database_Record'Class;
      E  : Entity_Information) return General_Entity;
   --  Convert Xref.Entity_Information to General_Entity

   procedure Fill_Entity_Array
     (Db   : General_Xref_Database;
      Curs : in out Entities_Cursor'Class;
      Arr  : in out Entity_Lists.List);
   --  Store all entities returned by the cursor into the array

   function To_Entity_Array (Arr : Entity_Lists.List) return Entity_Array;
   --  Creates an entity array.
   --  ??? This is not very efficient

   function Get_Entity_At_Location
     (Db  : access General_Xref_Database_Record'Class;
      Loc : General_Location) return Entity_Access;
   --  Return the construct entity found at the location given in parameter.

   procedure Reference_Iterator_Get_References
     (Self   : Xref_Database'Class;
      Entity : Entity_Information;
      Cursor : in out References_Cursor'Class);
   --  Wraps GNATCOLL.Xref.References to pass correct parameters

   procedure Close_Database (Self   : General_Xref_Database);
   --  Close the database connection (and perhaps remove the sqlite database
   --  if we were using a temporary project).

   procedure Open_Database (Self   : General_Xref_Database;
                            Tree   : Project_Tree_Access);
   --  Open the database connection

   ----------------
   -- Assistants --
   ----------------
   --  These types are used for the constructs database.

   LI_Assistant_Id : constant String := "LI_ASSISTANT";

   type LI_Db_Assistant is new Database_Assistant with record
      LI_Key : Construct_Annotations_Pckg.Annotation_Key;
      Db     : General_Xref_Database;
   end record;

   type LI_Db_Assistant_Access is access all LI_Db_Assistant'Class;

   type LI_Annotation is new
     Construct_Annotations_Pckg.General_Annotation_Record
   with record
      Entity : General_Entity;
   end record;

   overriding procedure Free (Obj : in out LI_Annotation);

   function To_LI_Entity
     (Self : access General_Xref_Database_Record'Class;
      E    : Entity_Access) return General_Entity;
   --  Return an LI entity based on a construct entity. Create one if none.

   ---------------
   -- To_String --
   ---------------

   function To_String (Loc : General_Location) return String is
   begin
      if Loc = No_Location then
         return "<no_loc>";
      else
         return Loc.File.Display_Base_Name & ':'
           & Image (Loc.Line, Min_Width => 1) & ':'
           & Image (Integer (Loc.Column), Min_Width => 1);
      end if;
   end To_String;

   -------------------
   -- Documentation --
   -------------------

   overriding procedure Documentation
     (Handler           : Language_Handlers.Language_Handler;
      Entity            : General_Entity;
      Formater          : access Profile_Formater'Class;
      Check_Constructs  : Boolean := True;
      Look_Before_First : Boolean := True)
   is
      function Doc_From_Constructs return Boolean;
      procedure Doc_From_LI;

      Decl : constant General_Location :=
        Get_Declaration (Entity).Loc;
      Context : constant Language.Language_Context_Access :=
        Language.Get_Language_Context
          (Get_Language_From_File (Handler, Source_Filename => Decl.File));

      -------------------------
      -- Doc_From_Constructs --
      -------------------------

      function Doc_From_Constructs return Boolean is
         Ent       : Entity_Access;
         Tree_Lang : Tree_Language_Access;
         Buffer    : GNAT.Strings.String_Access;
         Node      : Construct_Tree_Iterator;
      begin
         Node_From_Entity (Entity.Db, Handler, Decl, Ent, Tree_Lang);

         if Ent = Null_Entity_Access then
            return False;
         end if;

         Buffer := Get_Buffer (Get_File (Ent));
         Node   := To_Construct_Tree_Iterator (Ent);

         --  If the constructs have been properly loaded
         if Get_Construct (Node).Sloc_Start.Index /= 0 then
            declare
               Comment : constant String :=
                 Extract_Comment
                   (Buffer            => Buffer.all,
                    Decl_Start_Index  => Get_Construct (Node).Sloc_Start.Index,
                    Decl_End_Index    => Get_Construct (Node).Sloc_End.Index,
                    Language          => Context.Syntax,
                    Look_Before_First => Look_Before_First);
            begin
               Get_Profile (Tree_Lang, Ent, Formater, With_Aspects => True);

               if Comment /= "" then
                  Formater.Add_Comments (Comment);
               end if;

               return True;
            end;
         else
            return False;
         end if;
      end Doc_From_Constructs;

      -----------------
      -- Doc_From_LI --
      -----------------

      procedure Doc_From_LI is
         Buffer : GNAT.Strings.String_Access;
         Loc    : Old_Entities.File_Location;
         Result : Unbounded_String;
      begin
         if Active (SQLITE) then
            if Entity.Entity /= No_Entity then
               Formater.Add_Comments
                 (Ada.Strings.Fixed.Trim
                    (Entity.Db.Xref.Comment (Entity.Entity, Context.Syntax)
                     & ASCII.LF
                     & Entity.Db.Xref.Text_Declaration (Entity.Entity),
                  Left  => Ada.Strings.Maps.Null_Set,
                  Right => Ada.Strings.Maps.To_Set
                    (' ' & ASCII.HT & ASCII.LF & ASCII.CR)));
            end if;
         else
            Buffer := Decl.File.Read_File;

            if Buffer = null then
               return;
            end if;

            Result := To_Unbounded_String
              (Extract_Comment
                 (Buffer            => Buffer.all,
                  Decl_Start_Line   => Decl.Line,
                  Decl_Start_Column => Integer (Decl.Column),
                  Language          => Context.Syntax,
                  Look_Before_First => Look_Before_First));

            if Result = "" and then Entity.Old_Entity /= null then
               Find_Next_Body
                 (Entity.Old_Entity,
                  Location => Loc,
                  No_Location_If_First => True);

               if Loc /= Old_Entities.No_File_Location then
                  Free (Buffer);
                  Buffer := Old_Entities.Get_Filename (Loc.File).Read_File;
                  Result := To_Unbounded_String
                    (Extract_Comment
                       (Buffer            => Buffer.all,
                        Decl_Start_Line   => Loc.Line,
                        Decl_Start_Column => Integer (Loc.Column),
                        Language          => Context.Syntax,
                        Look_Before_First => Look_Before_First));
               end if;
            end if;

            Free (Buffer);
            Formater.Add_Comments (To_String (Result));
         end if;
      end Doc_From_LI;

   --  Start of processing for Documentation

   begin
      if not Check_Constructs then
         Doc_From_LI;
      else
         if not Doc_From_Constructs then
            Doc_From_LI;
         end if;
      end if;

      --  If still not found, we used to default to also searching just before
      --  the body. But when there is a separate spec, the doc should be there
      --  and when we don't have a separate spec the "declaration" is the
      --  location of the body.
   end Documentation;

   -------------------------------
   -- For_Each_Dispatching_Call --
   -------------------------------

   overriding procedure For_Each_Dispatching_Call
     (Entity    : General_Entity;
      Ref       : General_Entity_Reference;
      On_Callee : access function (Callee : Root_Entity'Class) return Boolean;
      Filter    : Reference_Kind_Filter := null)
   is
      use type Old_Entities.Reference_Kind;

      Prim_Ent  : General_Entity;

   begin
      --  Handle cases in which no action is needed

      if Entity = No_General_Entity
        or else not Entity.Db.Is_Dispatching_Call (Ref)
      then
         return;
      end if;

      if Active (SQLITE) then
         declare
            function Should_Show (E : Entity_Information) return Boolean;
            --  Whether we should display E

            -----------------
            -- Should_Show --
            -----------------

            function Should_Show (E : Entity_Information) return Boolean is
               R : References_Cursor;
            begin
               if Filter = null then
                  return True;
               end if;

               Entity.Db.Xref.References (E, R);
               while R.Has_Element loop
                  if Filter (Entity.Db, (Ref => R.Element, others => <>)) then
                     return True;
                  end if;
                  R.Next;
               end loop;
               return False;
            end Should_Show;

            Cursor : Recursive_Entities_Cursor;
            Prim   : Entity_Information;

         begin
            Prim     := Entity.Entity;
            Prim_Ent := To_General_Entity (Entity.Db, Prim);

            if Should_Show (Prim)
              and then not On_Callee (Callee => Prim_Ent)
            then
               return;
            end if;

            Recursive
              (Self    => Entity.Db.Xref,
               Entity  => Entity.Entity,
               Compute => Overridden_By'Unrestricted_Access,
               Cursor  => Cursor);

            while Cursor.Has_Element loop
               Prim     := Cursor.Element;
               Prim_Ent := To_General_Entity (Entity.Db, Prim);

               exit when Should_Show (Prim_Ent.Entity)
                 and then not On_Callee
                   (Callee       => Prim_Ent);

               Cursor.Next;
            end loop;

         exception
            when E : others =>
               Trace (Me, "Unexpected exception: "
                      & Exception_Information (E));
         end;

      --  Legacy functionality

      else
         declare
            function Proxy
              (Callee, Primitive_Of : Old_Entities.Entity_Information)
               return Boolean;
            function Proxy_Filter
              (R : Old_Entities.Entity_Reference) return Boolean;

            function Proxy
              (Callee, Primitive_Of : Old_Entities.Entity_Information)
               return Boolean
            is
               pragma Unreferenced (Primitive_Of);
            begin
               return On_Callee (From_Old (Callee));
            end Proxy;

            function Proxy_Filter
              (R : Old_Entities.Entity_Reference) return Boolean is
            begin
               return Filter (Entity.Db, (Old_Ref => R, others => <>));
            end Proxy_Filter;

            P : Old_Entities.Queries.Reference_Filter_Function := null;
            Need_Bodies : constant Boolean :=
              Filter = Reference_Is_Body'Access;

         begin
            if Filter /= null then
               P := Proxy_Filter'Unrestricted_Access;
            end if;

            Old_Entities.Queries.For_Each_Dispatching_Call
              (Entity      => Entity.Old_Entity,
               Ref         => Ref.Old_Ref,
               On_Callee   => Proxy'Access,
               Filter      => P,
               Need_Bodies => Need_Bodies,
               From_Memory => True);
         end;
      end if;
   end For_Each_Dispatching_Call;

   ----------------
   -- Get_Entity --
   ----------------

   function Get_Entity
     (Ref : General_Entity_Reference) return General_Entity
   is
      E : General_Entity;
   begin
      --  Attempt to use the sqlite system

      if Active (SQLITE)
        and then Ref.Ref /= No_Entity_Reference
      then
         E.Entity := Ref.Ref.Entity;
      end if;

      --  Fall back on the old system

      E.Old_Entity := Old_Entities.Get_Entity (Ref.Old_Ref);

      return E;
   end Get_Entity;

   ----------------
   -- Get_Entity --
   ----------------

   function Get_Entity
     (Db   : access General_Xref_Database_Record;
      Name : String;
      Loc  : General_Location) return Root_Entity'Class
   is
      Ref    : General_Entity_Reference;
   begin
      return Find_Declaration_Or_Overloaded
        (General_Xref_Database (Db),
         Loc               => Loc,
         Entity_Name       => Name,
         Ask_If_Overloaded => False,
         Closest_Ref       => Ref);
   end Get_Entity;

   ------------------------------------
   -- Find_Declaration_Or_Overloaded --
   ------------------------------------

   function Find_Declaration_Or_Overloaded
     (Self              : access General_Xref_Database_Record;
      Loc               : General_Location;
      Entity_Name       : String;
      Ask_If_Overloaded : Boolean := False;
      Closest_Ref       : out General_Entity_Reference;
      Approximate_Search_Fallback : Boolean := True) return Root_Entity'Class
   is
      Fuzzy : Boolean;

      function Internal_No_Constructs
        (Name : String; Loc : General_Location) return General_Entity;
      --  Search for the entity, without a fallback to the constructs db

      function Internal_No_Constructs
        (Name : String; Loc : General_Location) return General_Entity
      is
         Entity  : General_Entity := No_General_Entity;
         Set     : File_Info_Set;
         P       : Project_Type;
      begin
         if Active (SQLITE) then
            Closest_Ref.Db := General_Xref_Database (Self);

            if Loc = No_Location then
               --  predefined entities
               Closest_Ref.Ref := Self.Xref.Get_Entity
                 (Name    => Name,
                  File    => No_File,
                  Project => No_Project,
                  Approximate_Search_Fallback => Approximate_Search_Fallback);
            else
               if Loc.Project = No_Project then
                  Set := Self.Registry.Tree.Info_Set (Loc.File);
                  P := Set.First_Element.Project;
               else
                  P := Loc.Project;
               end if;

               --  Already handles the operators
               Closest_Ref.Ref := Self.Xref.Get_Entity
                 (Name    => Name,
                  File    => Loc.File,
                  Line    => Loc.Line,
                  Project => P,
                  Column  => Loc.Column,
                  Approximate_Search_Fallback => Approximate_Search_Fallback);
            end if;

            Entity.Entity := Closest_Ref.Ref.Entity;
            Fuzzy :=
              --  Multiple possible files ?
              (Loc.Project = No_Project and then Set.Length > 1)

              or else
                (Entity.Entity /= No_Entity and then
                   (Is_Fuzzy_Match (Entity.Entity)
                        --  or else not Self.Xref.Is_Up_To_Date (Loc.File)
                   ));

            declare
               ELoc : constant Entity_Reference :=
                 Self.Xref.Declaration (Entity.Entity).Location;
            begin
               if ELoc /= No_Entity_Reference then
                  Entity.Loc := (Line    => ELoc.Line,
                                 Project => ELoc.Project,
                                 Column  => ELoc.Column,
                                 File    => ELoc.File);
               else
                  Entity.Loc := No_Location;
               end if;
            end;

         else
            declare
               Status : Find_Decl_Or_Body_Query_Status;
               Source : Old_Entities.Source_File;
            begin
               --  ??? Should have a pref for the handling of fuzzy matches:
               --  - consider it as a no match: set Status to Entity_Not_Found
               --  - consider it as overloaded entity: same as below;
               --  - use the closest match: nothing to do.

               if Loc = No_Location then
                  --  A predefined entity
                  --  ??? Should not hard-code False here

                  Source := Old_Entities.Get_Predefined_File
                    (Self.Entities, Case_Sensitive => False);
                  Find_Declaration
                    (Db             => Self.Entities,
                     Source         => Source,
                     Entity_Name    => Name,
                     Line           => Loc.Line,  --  irrelevant
                     Column         => Loc.Column,  --  irrelevant
                     Entity         => Entity.Old_Entity,
                     Closest_Ref    => Closest_Ref.Old_Ref,
                     Status         => Status);

               else
                  Source := Old_Entities.Get_Or_Create
                    (Self.Entities, Loc.File, Allow_Create => True);
                  Find_Declaration
                    (Db             => Self.Entities,
                     Source         => Source,
                     Entity_Name    => Name,
                     Line           => Loc.Line,
                     Column         => Loc.Column,
                     Entity         => Entity.Old_Entity,
                     Closest_Ref    => Closest_Ref.Old_Ref,
                     Status         => Status);
               end if;

               Fuzzy := Status = Overloaded_Entity_Found
                 or else Status = Fuzzy_Match;

               if Status = Entity_Not_Found
                 and then Name /= ""
                 and then Name (Name'First) = '"'
               then
                  --  Try without the quotes
                  Entity := General_Entity
                    (Find_Declaration_Or_Overloaded
                       (Self              => Self,
                        Loc               => Loc,
                        Entity_Name       => Entity_Name
                          (Entity_Name'First + 1 .. Entity_Name'Last - 1),
                        Ask_If_Overloaded => Ask_If_Overloaded,
                        Closest_Ref       => Closest_Ref));
               end if;
            end;
         end if;

         Entity.Is_Fuzzy := Fuzzy;
         return Entity;
      end Internal_No_Constructs;

      Entity : Root_Entity'Class := General_Entity'Class (No_General_Entity);

   begin
      Closest_Ref := No_General_Entity_Reference;

      if Entity_Name = "" then
         Entity := No_Root_Entity;
         return Entity;
      end if;

      if Active (Me) then
         Increase_Indent (Me, "Find_Declaration of " & Entity_Name
                          & " file=" & Loc.File.Display_Base_Name
                          & " project=" & Loc.Project.Name
                          & " line=" & Loc.Line'Img
                          & " col=" & Loc.Column'Img);
      end if;

      Entity := General_Entity'Class
        (Internal_No_Constructs (Entity_Name, Loc));
      --  also sets Fuzzy

      if Fuzzy and then Ask_If_Overloaded then
         Entity := Select_Entity_Declaration
           (Self => Self,
            File   => Loc.File,
            Project => Loc.Project,
            Entity => Entity);

         if Active (Me) then
            Decrease_Indent (Me);
         end if;
         General_Entity (Entity).Db := General_Xref_Database (Self);
         return Entity;
      end if;

      --  Fallback on constructs

      if (Entity = No_Root_Entity or else Fuzzy)
        and then Active (Constructs_Heuristics)
        and then Loc /= No_Location   --  Nothing for predefined entities
      then
         declare
            Tree_Lang : Tree_Language_Access;
            Result       : Entity_Access;
            Result_Loc   : Source_Location;
            New_Location : General_Location;
            New_Entity   : General_Entity := No_General_Entity;

         begin
            Trace (Me, "Searching entity declaration in constructs");
            Node_From_Entity
              (Self,
               Handler   => Self.Lang_Handler,
               Decl      => Loc,
               Ent       => Result,
               Tree_Lang => Tree_Lang,
               Name      => Entity_Name);

            if Result /= Null_Entity_Access
               and then
                  (Entity_Name = "" or else
                   Get (Get_Construct (Result).Name).all = Entity_Name)
            then
               Result_Loc := Get_Construct (Result).Sloc_Entity;

               --  First, try to see if there's already a similar entity in
               --  the database. If that's the case, it's better to use it
               --  than the dummy one created from the construct.

               if Result_Loc.Line > 0 then
                  New_Location :=
                    (File    => Get_File_Path (Get_File (Result)),
                     Project => Loc.Project.Create_From_Project
                       (Get_File_Path (Get_File (Result)).Full_Name.all)
                       .Project,
                     Line    => Result_Loc.Line,
                     Column  => To_Visible_Column
                       (Get_File (Result),
                        Result_Loc.Line,
                        String_Index_Type (Result_Loc.Column)));

                  New_Entity := Internal_No_Constructs
                    (Name  => Get (Get_Construct (Result).Name).all,
                     Loc   => (File    => New_Location.File,
                               Project => New_Location.Project,
                               Line    => New_Location.Line,
                               Column  => New_Location.Column));
               end if;

               if New_Entity /= No_General_Entity
                 and then not Is_Fuzzy (New_Entity)
               then
                  --  If we found an updated ALI entity, use it.
                  Entity := General_Entity'Class (New_Entity);

               elsif Entity /= No_Root_Entity then
                  --  Reuse the ALI entity, since that gives us a chance to
                  --  query its references as well.
                  General_Entity'Class (Entity).Loc := New_Location;

               else
                  --  If we have no entity to connect to, then create one
                  --  from the construct database.

                  Entity := General_Entity'Class (To_LI_Entity (Self, Result));
               end if;

               General_Entity'Class (Entity).Is_Fuzzy := True;
            end if;
         end;
      end if;

      if Active (Me) then
         Decrease_Indent (Me);
      end if;

      General_Entity (Entity).Db := General_Xref_Database (Self);
      return Entity;
   end Find_Declaration_Or_Overloaded;

   --------------
   -- Get_Name --
   --------------

   overriding function Get_Name
     (Entity : General_Entity) return String is
   begin
      if Active (SQLITE) then
         if Entity.Entity /= No_Entity then
            return To_String
              (Declaration (Entity.Db.Xref.all, Entity.Entity).Name);
         elsif Entity.Loc /= No_Location then
            declare
               C : constant access Simple_Construct_Information :=
                 Construct_From_Entity (Entity.Db, Entity);
            begin
               return Get (C.Name).all;
            end;
         end if;
      else
         if Entity.Old_Entity /= null then
            return Get (Old_Entities.Get_Name (Entity.Old_Entity)).all;
         end if;
      end if;

      return "";
   end Get_Name;

   --------------------
   -- Qualified_Name --
   --------------------

   overriding function Qualified_Name
     (Entity : General_Entity) return String
   is
   begin
      if Active (SQLITE) then
         if Entity.Entity /= No_Entity then
            return Entity.Db.Xref.Qualified_Name (Entity.Entity);
         end if;
      else
         if Entity.Old_Entity /= null then
            return Old_Entities.Queries.Get_Full_Name (Entity.Old_Entity);
         end if;
      end if;

      return "";
   end Qualified_Name;

   ------------------
   -- Get_Location --
   ------------------

   function Get_Location
     (Ref : General_Entity_Reference) return General_Location is
   begin
      if Active (SQLITE) then
         if Ref.Ref /= No_Entity_Reference then
            return Get_Location (Ref.Ref);
         end if;

      else
         declare
            use Old_Entities;
            Loc : constant Old_Entities.File_Location :=
              Old_Entities.Get_Location (Ref.Old_Ref);
         begin
            if Loc.File /= null then
               return (File    => Old_Entities.Get_Filename (Loc.File),
                       Project => No_Project,  --  unknown
                       Line    => Loc.Line,
                       Column  => Loc.Column);
            end if;
         end;
      end if;
      return No_Location;
   end Get_Location;

   ------------------
   -- Get_Location --
   ------------------

   function Get_Location
     (Ref : Entity_Reference) return General_Location is
   begin
      if Ref = No_Entity_Reference then
         return No_Location;
      else
         return
           (File    => Ref.File,
            Project => Ref.Project,
            Line    => Ref.Line,
            Column  => Visible_Column_Type (Ref.Column));
      end if;
   end Get_Location;

   ---------------------------
   -- Caller_At_Declaration --
   ---------------------------

   overriding function Caller_At_Declaration
     (Entity : General_Entity) return Root_Entity'Class
   is
   begin
      if Active (SQLITE) then
         return General_Entity'
           (Entity => Entity.Db.Xref.Declaration
              (Entity.Entity).Location.Scope,
            Db     => Entity.Db,
            others => <>);
      else
         return General_Entity'
           (Old_Entity =>
              Old_Entities.Queries.Get_Caller
                (Old_Entities.Declaration_As_Reference
                     (Entity.Old_Entity)),
            Db     => Entity.Db,
            others => <>);
      end if;
   end Caller_At_Declaration;

   ---------------------
   -- Get_Declaration --
   ---------------------

   overriding function Get_Declaration
     (Entity : General_Entity) return General_Entity_Declaration is
   begin
      if Entity.Loc /= No_Location then
         declare
            Result    : Entity_Access;
            Tree_Lang : Tree_Language_Access;
            Decl      : Entity_Access;
            Node      : Construct_Tree_Iterator;
            Cat       : Language_Category;
            Project   : Project_Type;
         begin
            Node_From_Entity
              (Entity.Db,
               Entity.Db.Lang_Handler,
               Entity.Loc, Result, Tree_Lang);

            if Result /= Null_Entity_Access then
               Decl := Get_Declaration
                  (Get_Tree_Language (Get_File (Result)), Result);
               Node := To_Construct_Tree_Iterator (Decl);
               Cat := Get_Construct (Node).Category;

               --  Find the project that controls the file (in the case of
               --  aggregate projects)
               Project := Entity.Loc.Project.Create_From_Project
                 (Get_File_Path (Get_File (Decl)).Full_Name.all)
                 .Project;

               return (Loc => (File    => Get_File_Path (Get_File (Decl)),
                               Project => Project,
                               Line   => Get_Construct (Node).Sloc_Entity.Line,
                               Column => Visible_Column_Type
                                 (Get_Construct (Node).Sloc_Entity.Column)),
                       Body_Is_Full_Declaration =>
                         Cat = Cat_Type or else Cat = Cat_Class,
                       Name =>
                         To_Unbounded_String
                           (Get (Get_Construct (Node).Name).all));
            end if;
         end;
      end if;

      if Active (SQLITE) then
         if Entity.Entity /= No_Entity then
            declare
               Ref : constant Entity_Declaration :=
                 Entity.Db.Xref.Declaration (Entity.Entity);
            begin
               if Ref /= No_Entity_Declaration then
                  return (Loc    => (File    => Ref.Location.File,
                                     Project => Ref.Location.Project,
                                     Line    => Ref.Location.Line,
                                     Column  => Ref.Location.Column),
                          Body_Is_Full_Declaration =>
                            Ref.Flags.Body_Is_Full_Declaration,
                          Name   => Ref.Name);
               end if;
            end;
         end if;

      else
         if Entity.Old_Entity /= null then
            declare
               Loc : constant Old_Entities.File_Location :=
                 Old_Entities.Get_Declaration_Of (Entity.Old_Entity);
            begin
               return (Loc => (File   => Old_Entities.Get_Filename (Loc.File),
                               Project => No_Project,  --  ??? unknown
                               Line   => Loc.Line,
                               Column => Loc.Column),
                       Body_Is_Full_Declaration =>
                         Old_Entities.Body_Is_Full_Declaration
                           (Old_Entities.Get_Kind (Entity.Old_Entity).Kind),
                       Name => To_Unbounded_String
                         (Get
                            (Old_Entities.Get_Name (Entity.Old_Entity)).all));
            end;
         end if;
      end if;

      return No_General_Entity_Declaration;
   end Get_Declaration;

   ----------------------------
   -- Get_Entity_At_Location --
   ----------------------------

   function Get_Entity_At_Location
     (Db     : access General_Xref_Database_Record'Class;
      Loc : General_Location) return Entity_Access
   is
      S_File : constant Structured_File_Access :=
        Get_Or_Create
          (Db   => Db.Constructs,
           File => Loc.File);
      Construct : Construct_Tree_Iterator;
   begin
      Update_Contents (S_File);

      Construct :=
        Get_Iterator_At
          (Tree      => Get_Tree (S_File),
           Location  => To_Location
             (Loc.Line,
              To_Line_String_Index
                (S_File,
                 Loc.Line,
                 Loc.Column)),
           From_Type => Start_Name);

      if Construct /= Null_Construct_Tree_Iterator then
         return To_Entity_Access (S_File, Construct);
      else
         return Null_Entity_Access;
      end if;
   end Get_Entity_At_Location;

   --------------
   -- Get_Body --
   --------------

   overriding function Get_Body
     (Entity : General_Entity;
      After  : General_Location := No_Location) return General_Location
   is
      No_Location_If_First : constant Boolean := False;

      function Extract_Next_By_Heuristics return General_Location;
      --  Return the next body location using the construct heuristics

      function Is_Location_For_Entity
        (Location : General_Location) return Boolean;
      --  Return true if the location given in parameter indeed corresponds to
      --  a declaration construct, false otherwise, typically when the file has
      --  been modified and the ali retreived is not up to date.
      --  Note that if the construct database is deactivated, this will always
      --  return true (we're always on the expected construct, we don't expect
      --  anything in particular).

      ----------------------------
      -- Is_Location_For_Entity --
      ----------------------------

      function Is_Location_For_Entity
        (Location : General_Location) return Boolean
      is
         C_Entity : Entity_Access;
      begin
         if Active (Constructs_Heuristics) then
            C_Entity := Get_Entity_At_Location (Entity.Db, Location);

            --  Return true if we found a construct here and if it's of the
            --  appropriate name.

            return C_Entity /= Null_Entity_Access
              and then Get (Get_Identifier (C_Entity)).all =
              Get_Name (Entity);
         end if;

         return True;
      end Is_Location_For_Entity;

      --------------------------------
      -- Extract_Next_By_Heuristics --
      --------------------------------

      function Extract_Next_By_Heuristics return General_Location is
         C_Entity, New_Entity : Entity_Access := Null_Entity_Access;
         Loc : General_Location;
         P   : Project_Type;

      begin
         --  In order to locate the reference to look from, we check if there
         --  is a file associated to the input location. In certain cases, this
         --  location is computed from a context that does not have file
         --  information, so for safety purpose, we check that the file exist
         --  (there's nothing we can do at the completion level without a
         --  file). If there's no file, then the context has been partially
         --  provided (or not at all) so we start from the declaration of the
         --  Entity.

         if Active (Constructs_Heuristics) then
            if After /= No_Location then
               C_Entity := Get_Entity_At_Location (Entity.Db, After);
            end if;

            if C_Entity = Null_Entity_Access then
               if Entity.Loc /= No_Location then
                  C_Entity := Get_Entity_At_Location (Entity.Db, Entity.Loc);
               else
                  Loc := Get_Declaration (Entity).Loc;
                  if Loc /= No_Location then
                     C_Entity := Get_Entity_At_Location (Entity.Db, Loc);
                  end if;
               end if;
            end if;

            if C_Entity /= Null_Entity_Access then
               declare
                  S_File : constant Structured_File_Access :=
                    Get_File (C_Entity);

                  Tree_Lang : constant Tree_Language_Access :=
                    Get_Tree_Language_From_File
                      (Entity.Db.Lang_Handler, Get_File_Path (S_File));
               begin
                  New_Entity := Tree_Lang.Find_Next_Part (C_Entity);

                  --  If we're initializing a loop, e.g. the current location
                  --  is no location, then return the result. Otherwise, don't
                  --  return it if we got back to the initial body and the
                  --  caller doesn't want to loop back.

                  if After /= No_Location
                    and then No_Location_If_First
                    and then C_Entity = Tree_Lang.Find_First_Part (C_Entity)
                  then
                     return No_Location;
                  end if;

                  if New_Entity /= C_Entity then
                     P := Loc.Project.Create_From_Project
                       (Get_File_Path (Get_File (New_Entity)).Full_Name.all)
                       .Project;

                     return
                       (File    => Get_File_Path (Get_File (New_Entity)),
                        Project => P,
                        Line    => Get_Construct (New_Entity).Sloc_Entity.Line,
                        Column  =>
                          To_Visible_Column
                            (Get_File (New_Entity),
                             Get_Construct (New_Entity).Sloc_Entity.Line,
                             String_Index_Type
                               (Get_Construct (New_Entity).Sloc_Entity.Column
                               )));
                  end if;
               end;
            end if;
         end if;

         return No_Location;
      end Extract_Next_By_Heuristics;

      Candidate : General_Location := No_Location;
      Decl_Loc : constant General_Location := Get_Declaration (Entity).Loc;

   begin
      if Active (Me) then
         Increase_Indent (Me, "Get_Body of "
                          & Get_Name (Entity)
                          & " fuzzy=" & Is_Fuzzy (Entity)'Img);
      end if;

      if After = No_Location
        or else After = Decl_Loc
      then
         declare
            H_Loc : constant General_Location := Extract_Next_By_Heuristics;
         begin
            if Active (Me) then
               Trace (Me, "Body computed from constructs at "
                      & To_String (H_Loc));
            end if;

            if H_Loc /= No_Location and then
            --  If we found nothing, use the information from the constructs.
              (Candidate = No_Location

               --  it's OK to return the first entity.
               or else (not No_Location_If_First
                        and then not Is_Location_For_Entity (Candidate)))

            then
               Candidate := H_Loc;

               --  else if the candidate is at the expected location and if
               if Active (Me) then
                  Trace (Me, "Use body from constructs");
               end if;

               --  If we don't have any more information to extract from the
               --  construct database, then return the first entity if allowed
               --  by the flags, or null.

            elsif No_Location_If_First then
               Candidate := No_Location;
            end if;
         end;
      end if;

      if Candidate /= No_Location then
         if Active (Me) then
            Decrease_Indent (Me);
         end if;
         return Candidate;
      end if;

      if Active (SQLITE) then
         if Entity.Entity /= No_Entity then
            declare
               C   : References_Cursor;
               Ref : Entity_Reference;
               Matches : Boolean := After = No_Location;
               First  : General_Location := No_Location;
               Is_First : Boolean := True;
            begin
               Bodies (Entity.Db.Xref.all, Entity.Entity, Cursor => C);
               while Has_Element (C) loop
                  Ref := Element (C);

                  if Ref /= No_Entity_Reference then
                     if Is_First then
                        Is_First := False;
                        First := (File    => Ref.File,
                                  Project => Ref.Project,
                                  Line    => Ref.Line,
                                  Column  => Visible_Column_Type (Ref.Column));
                     end if;

                     if Matches then
                        Candidate :=
                          (File    => Ref.File,
                           Project => Ref.Project,
                           Line    => Ref.Line,
                           Column  => Visible_Column_Type (Ref.Column));
                        exit;
                     else
                        Matches := Ref.Line = After.Line
                          and then Ref.Column = After.Column
                          and then Ref.File = After.File;
                     end if;
                  end if;

                  Next (C);
               end loop;

               if Candidate = No_Location then
                  --  The "After" parameter did not correspond to a body
                  Candidate := First;
               end if;
            end;
         end if;

      else
         if Entity.Old_Entity /= null then
            declare
               Loc : Old_Entities.File_Location;
            begin
               if After /= No_Location then
                  Find_Next_Body
                    (Entity           => Entity.Old_Entity,
                     Current_Location =>
                       (File   => Old_Entities.Get_Or_Create
                            (Entity.Db.Entities,
                             After.File, Allow_Create => True),
                        Line   => After.Line,
                        Column => After.Column),
                     Location         => Loc);
               else
                  Find_Next_Body
                    (Entity           => Entity.Old_Entity,
                     Current_Location => Old_Entities.No_File_Location,
                     Location         => Loc);
               end if;

               if Loc /= Old_Entities.No_File_Location then
                  if Active (Me) then
                     Trace (Me, "Found " & Old_Entities.To_String (Loc));
                  end if;

                  Candidate :=
                    (File    => Old_Entities.Get_Filename (Loc.File),
                     Project => No_Project,  --  unknown
                     Line    => Loc.Line,
                     Column  => Loc.Column);
               else
                  Trace (Me, "No body found");
               end if;
            end;
         end if;
      end if;

      if Active (Me) then
         Decrease_Indent (Me);
      end if;

      return Candidate;
   end Get_Body;

   -----------------
   -- Get_Type_Of --
   -----------------

   overriding function Get_Type_Of
     (Entity : General_Entity) return Root_Entity'Class
   is
   begin
      if not Active (SQLITE) then
         declare
            E : constant Old_Entities.Entity_Information :=
                  Old_Entities.Get_Type_Of (Entity.Old_Entity);
         begin
            return From_Old (E);
         end;
      else
         return From_New (Entity.Db, Entity.Db.Xref.Type_Of (Entity.Entity));
      end if;
   end Get_Type_Of;

   -------------------
   -- Returned_Type --
   -------------------

   overriding function Returned_Type
     (Entity : General_Entity) return Root_Entity'Class is
   begin
      if Active (SQLITE) then
         return From_New (Entity.Db, Entity.Db.Xref.Type_Of (Entity.Entity));
      else
         return From_Old (Old_Entities.Get_Returned_Type (Entity.Old_Entity));
      end if;
   end Returned_Type;

   --------------------------
   -- Is_Predefined_Entity --
   --------------------------

   overriding function Is_Predefined_Entity
     (E  : General_Entity) return Boolean is
   begin
      if not Active (SQLITE) then
         return Old_Entities.Is_Predefined_Entity (E.Old_Entity);
      else
         return Is_Predefined_Entity
           (Declaration (E.Db.Xref.all, E.Entity));
      end if;
   end Is_Predefined_Entity;

   ----------------------
   -- Node_From_Entity --
   ----------------------

   procedure Node_From_Entity
     (Self        : access General_Xref_Database_Record'Class;
      Handler     : access Abstract_Language_Handler_Record'Class;
      Decl        : General_Location;
      Ent         : out Entity_Access;
      Tree_Lang   : out Tree_Language_Access;
      Name        : String := "")
   is
      Data_File   : Structured_File_Access;
   begin
      Ent := Null_Entity_Access;
      Tree_Lang := Get_Tree_Language_From_File (Handler, Decl.File, False);
      Data_File := Language.Tree.Database.Get_Or_Create
        (Db   => Self.Constructs,
         File => Decl.File);
      Update_Contents (Data_File);

      --  In some cases, the references are extracted from a place
      --  where there is still an ALI file, but no more source file.
      --  This will issue a null Structured_File_Access, which is why
      --  we're protecting the following code with the above condition

      if not Is_Null (Data_File) then
         --  Find_Declaration does more than Get_Iterator_At, so use it.
         Ent := Tree_Lang.Find_Declaration
            (Data_File, Decl.Line,
             To_Line_String_Index (Data_File, Decl.Line, Decl.Column));
      end if;

      if Ent = Null_Entity_Access
        and then Name /= ""
      then
         declare
            It : Construct_Db_Iterator := Self.Constructs.Start (Name, True);
         begin
            if not At_End (It) then
               Ent := Get (It);
               Next (It);
            end if;

            --  Return a null result if there is more than one result

            if not At_End (It) then
               Ent := Null_Entity_Access;
            end if;
         end;
      end if;

   end Node_From_Entity;

   ---------------------------
   -- Construct_From_Entity --
   ---------------------------

   function Construct_From_Entity
     (Self : access General_Xref_Database_Record'Class;
      Entity : General_Entity) return access Simple_Construct_Information is
   begin
      declare
         Result    : Entity_Access;
         Tree_Lang : Tree_Language_Access;
         Decl      : Entity_Access;
         Node      : Construct_Tree_Iterator;
      begin
         Node_From_Entity
           (Self, Self.Lang_Handler, Entity.Loc, Result, Tree_Lang);

         if Result /= Null_Entity_Access then
            Decl := Get_Declaration
              (Get_Tree_Language (Get_File (Result)), Result);
            Node := To_Construct_Tree_Iterator (Decl);
            return Get_Construct (Node);
         end if;
         return null;
      end;
   end Construct_From_Entity;

   ------------------
   -- Pointed_Type --
   ------------------

   overriding function Pointed_Type
     (Entity : General_Entity) return Root_Entity'Class
   is
   begin
      if Active (SQLITE) then
         return From_New
           (Entity.Db, Entity.Db.Xref.Pointed_Type (Entity.Entity));
      else
         return From_Old
           (Old_Entities.Queries.Pointed_Type (Entity.Old_Entity));
      end if;
   end Pointed_Type;

   ---------
   -- Ref --
   ---------

   overriding procedure Ref (Entity : General_Entity) is
   begin
      Old_Entities.Ref (Entity.Old_Entity);
   end Ref;

   -----------------------
   -- To_General_Entity --
   -----------------------

   function To_General_Entity
     (Db : access General_Xref_Database_Record'Class;
      E  : Entity_Information) return General_Entity
   is
      Decl : constant Entity_Declaration := Declaration (Db.Xref.all, E);
      Loc  : General_Location;

   begin
      pragma Assert (Active (SQLITE));

      Loc :=
        (File    => Decl.Location.File,
         Project => Decl.Location.Project,
         Line    => Decl.Location.Line,
         Column  => Visible_Column_Type (Decl.Location.Column));

      return General_Entity (Get_Entity
                             (Db   => Db,
                              Name => To_String (Decl.Name),
                              Loc  => Loc));
   end To_General_Entity;

   -----------------------
   -- To_General_Entity --
   -----------------------

   function To_General_Entity
     (E  : Old_Entities.Entity_Information) return General_Entity is
   begin
      pragma Assert (not Active (SQLITE));

      if E = null then
         return No_General_Entity;
      else
         return General_Entity'(Old_Entity => E, others => <>);
      end if;
   end To_General_Entity;

   -----------
   -- Unref --
   -----------

   overriding procedure Unref (Entity : in out General_Entity) is
   begin
      Old_Entities.Unref (Entity.Old_Entity);
   end Unref;

   -----------------
   -- Renaming_Of --
   -----------------

   overriding function Renaming_Of
     (Entity : General_Entity) return Root_Entity'Class
   is
   begin
      if Active (SQLITE) then
         return General_Entity'
           (Entity => Entity.Db.Xref.Renaming_Of (Entity.Entity),
            Db     => Entity.Db,
            others => <>);
      else
         return
           General_Entity'
             (Old_Entity =>
                Old_Entities.Queries.Renaming_Of (Entity.Old_Entity),
              Db     => Entity.Db,
              others => <>);
      end if;
   end Renaming_Of;

   ---------
   -- "=" --
   ---------

   overriding function "="
     (Ref1, Ref2 : General_Entity_Reference) return Boolean
   is
      use Old_Entities;
   begin
      if Active (SQLITE) then
         return Ref1.Ref = Ref2.Ref;
      else
         return Ref1.Old_Ref = Ref2.Old_Ref;
      end if;
   end "=";

   ---------
   -- "=" --
   ---------

   overriding function "=" (E1, E2 : General_Entity) return Boolean is
   begin
      if Active (SQLITE) then
         if E1.Entity = No_Entity and then E2.Entity = No_Entity then
            return E1.Loc = E2.Loc;
         else
            return E1.Entity = E2.Entity;
         end if;
      else
         return E1.Old_Entity = E2.Old_Entity;
      end if;
   end "=";

   -------------------------
   -- Find_All_References --
   -------------------------

   procedure Find_All_References
      (Self     : access General_Xref_Database_Record;
       Iter     : out Entity_Reference_Iterator;
       File     : GNATCOLL.VFS.Virtual_File;
       Kind     : String := "";
       Sort     : References_Sort := GNATCOLL.Xref.By_Location) is
   begin
      if Active (SQLITE) then
         Iter.Db := General_Xref_Database (Self);
         Self.Xref.References
            (File => File, Cursor => Iter.Iter, Kind => Kind, Sort => Sort);
      else
         Iter.Old_Iter := No_Entity_Reference_Iterator;
      end if;
   end Find_All_References;

   ---------------------------------------
   -- Reference_Iterator_Get_References --
   ---------------------------------------

   procedure Reference_Iterator_Get_References
     (Self   : Xref_Database'Class;
      Entity : Entity_Information;
      Cursor : in out References_Cursor'Class)
   is
      C : constant GPS_Recursive_References_Cursor :=
         GPS_Recursive_References_Cursor (Cursor);
   begin
      Self.References
        (Entity, Cursor,
         Include_Implicit => C.Include_Implicit,
         Include_All      => C.Include_All,
         Kinds            => To_String (C.Kind));
   end Reference_Iterator_Get_References;

   -------------------------
   -- Find_All_References --
   -------------------------

   overriding procedure Find_All_References
     (Iter                  : out Entity_Reference_Iterator;
      Entity                : General_Entity;
      File_Has_No_LI_Report : Basic_Types.File_Error_Reporter := null;
      In_File              : GNATCOLL.VFS.Virtual_File := GNATCOLL.VFS.No_File;
      In_Scope              : Root_Entity'Class := No_Root_Entity;
      Include_Overriding    : Boolean := False;
      Include_Overridden    : Boolean := False;
      Include_Implicit      : Boolean := False;
      Include_All           : Boolean := False;
      Kind                  : String := "")
   is
      F      : Old_Entities.Source_File;
   begin
      if Active (SQLITE) then
         --  File_Has_No_LI_Report voluntarily ignored.

         Iter.Db := Entity.Db;
         Iter.Iter.Include_Implicit := Include_Implicit;
         Iter.Iter.Include_All := Include_All;
         Iter.Iter.Kind := To_Unbounded_String (Kind);
         Entity.Db.Xref.Recursive
           (Entity          => Entity.Entity,
            Compute         => Reference_Iterator_Get_References'Access,
            Cursor          => Iter.Iter,
            From_Overriding => Include_Overriding,
            From_Overridden => Include_Overridden,
            From_Renames    => True);
         Iter.In_File  := In_File;
         Iter.In_Scope := General_Entity (In_Scope);

         while Has_Element (Iter.Iter)
           and then
             ((Iter.In_File /= No_File
               and then Iter.Iter.Element.File /= Iter.In_File)
              or else
                (Iter.In_Scope /= No_General_Entity
                 and then Iter.Iter.Element.Scope /= Iter.In_Scope.Entity))
         loop
            Iter.Iter.Next;
         end loop;

      else
         declare
            use Old_Entities;
            Filter : Old_Entities.Reference_Kind_Filter;
            R : String_List_Access;
         begin
            if Kind /= "" then
               Filter := (others => False);
               R := GNATCOLL.Utils.Split (Kind, ',');

               for K in Filter'Range loop
                  declare
                     KS : constant String := Kind_To_String (K);
                  begin
                     for F2 in R'Range loop
                        if KS = R (F2).all then
                           Filter (K) := True;
                           exit;
                        end if;
                     end loop;
                  end;
               end loop;

               Free (R);

            elsif Include_All then
               Filter := (others => True);
            else
               Filter := Real_References_Filter;
               if Include_Implicit then
                  Filter (Implicit) := True;
               end if;
            end if;

            if In_File /= No_File then
               F := Old_Entities.Get_Or_Create
                 (Db    => Entity.Db.Entities,
                  File  => In_File,
                  Allow_Create => True);
            end if;

            Old_Entities.Queries.Find_All_References
              (Iter.Old_Iter, Entity.Old_Entity,
               File_Has_No_LI_Report, F, General_Entity (In_Scope).Old_Entity,
               Filter             => Filter,
               Include_Overriding => Include_Overriding,
               Include_Overridden => Include_Overridden);
         end;
      end if;
   end Find_All_References;

   ------------
   -- At_End --
   ------------

   function At_End (Iter : Entity_Reference_Iterator) return Boolean is
   begin
      if Active (SQLITE) then
         return not Has_Element (Iter.Iter);
      else
         return At_End (Iter.Old_Iter);
      end if;
   end At_End;

   ----------
   -- Next --
   ----------

   procedure Next (Iter : in out Entity_Reference_Iterator) is
      use Old_Entities;
   begin
      if Active (SQLITE) then
         Next (Iter.Iter);

         while Has_Element (Iter.Iter)
           and then
             ((Iter.In_File /= No_File
               and then Iter.Iter.Element.File /= Iter.In_File)
              or else
                (Iter.In_Scope /= No_General_Entity
                 and then Iter.Iter.Element.Scope /= Iter.In_Scope.Entity))
         loop
            Iter.Iter.Next;
         end loop;

      else
         Next (Iter.Old_Iter);
      end if;
   end Next;

   ---------
   -- Get --
   ---------

   function Get
     (Iter : Entity_Reference_Iterator) return General_Entity_Reference
   is
   begin
      if Active (SQLITE) then
         return (Old_Ref => Old_Entities.No_Entity_Reference,
                 Db      => Iter.Db,
                 Ref     => Iter.Iter.Element);
      else
         return (Old_Ref => Get (Iter.Old_Iter),
                 Db      => Iter.Db,
                 Ref     => No_Entity_Reference);
      end if;
   end Get;

   ----------------
   -- Get_Entity --
   ----------------

   function Get_Entity
     (Iter : Entity_Reference_Iterator) return Root_Entity'Class is
   begin
      if Active (SQLITE) then
         return General_Entity'(Entity     => Iter.Iter.Element.Entity,
                                Db         => Iter.Db,
                                others     => <>);
      else
         return To_General_Entity (Get_Entity (Iter.Old_Iter));
      end if;
   end Get_Entity;

   -------------
   -- Destroy --
   -------------

   procedure Destroy (Iter : in out Entity_Reference_Iterator) is
   begin
      if Active (SQLITE) then
         null;
      else
         Destroy (Iter.Old_Iter);
      end if;
   end Destroy;

   -------------
   -- Destroy --
   -------------

   procedure Destroy (Iter : in out Entity_Reference_Iterator_Access) is
      procedure Unchecked_Free is new Ada.Unchecked_Deallocation
        (Entity_Reference_Iterator,
         Entity_Reference_Iterator_Access);
   begin
      if Iter /= null then
         Destroy (Iter.all);
         Unchecked_Free (Iter);
      end if;
   end Destroy;

   --------------------------
   -- Get_Current_Progress --
   --------------------------

   function Get_Current_Progress
     (Iter : Entity_Reference_Iterator) return Integer is
   begin
      if Active (SQLITE) then
         return 1;
      else
         return Get_Current_Progress (Iter.Old_Iter);
      end if;
   end Get_Current_Progress;

   ------------------------
   -- Get_Total_Progress --
   ------------------------

   function Get_Total_Progress
     (Iter : Entity_Reference_Iterator) return Integer is
   begin
      if Active (SQLITE) then
         --  precomputing the number of references is expensive (basically
         --  requires doing the query twice), and won't be needed anymore when
         --  we get rid of the asynchronous iterators.
         return 1;
      else
         return Get_Total_Progress (Iter.Old_Iter);
      end if;
   end Get_Total_Progress;

   -----------------------
   -- Show_In_Callgraph --
   -----------------------

   function Show_In_Callgraph
     (Db  : access General_Xref_Database_Record;
      Ref : General_Entity_Reference) return Boolean
   is
   begin
      if Active (SQLITE) then
         return Db.Xref.Show_In_Callgraph (Ref.Ref);
      else
         return Old_Entities.Show_In_Call_Graph
           (Db.Entities, Old_Entities.Get_Kind (Ref.Old_Ref));
      end if;
   end Show_In_Callgraph;

   ----------------
   -- Get_Caller --
   ----------------

   function Get_Caller
     (Ref : General_Entity_Reference) return Root_Entity'Class
   is
   begin
      if Active (SQLITE) then
         return General_Entity'
           (Entity => Ref.Ref.Scope,
            Db => Ref.Db,
            others => <>);
      else
         return
           General_Entity'
             (Old_Entity => Old_Entities.Queries.Get_Caller (Ref.Old_Ref),
              Db => Ref.Db,
              others => <>);
      end if;
   end Get_Caller;

   -------------------
   -- Is_Subprogram --
   -------------------

   overriding function Is_Subprogram
     (E  : General_Entity) return Boolean
   is
   begin
      if Active (SQLITE) then
         if E.Entity /= No_Entity then
            return E.Db.Xref.Declaration (E.Entity).Flags.Is_Subprogram;
         elsif E.Loc /= No_Location then
            declare
               C : constant access Simple_Construct_Information :=
                 Construct_From_Entity (E.Db, E);
            begin
               return
                 C.Category = Cat_Function or else C.Category = Cat_Procedure;
            end;
         end if;
         return False;
      else
         return Old_Entities.Is_Subprogram (E.Old_Entity);
      end if;
   end Is_Subprogram;

   ------------------
   -- Is_Container --
   ------------------

   overriding function Is_Container
     (E  : General_Entity) return Boolean
   is
   begin
      if Active (SQLITE) then
         return E.Db.Xref.Declaration (E.Entity).Flags.Is_Container;
      else
         return Old_Entities.Is_Container
           (Old_Entities.Get_Kind (E.Old_Entity).Kind);
      end if;
   end Is_Container;

   ----------------
   -- Is_Generic --
   ----------------

   overriding function Is_Generic
     (E  : General_Entity) return Boolean
   is
   begin
      if Active (SQLITE) then
         return E.Db.Xref.Declaration (E.Entity).Flags.Is_Generic;
      else
         return Old_Entities.Get_Kind (E.Old_Entity).Is_Generic;
      end if;
   end Is_Generic;

   ---------------
   -- Is_Global --
   ---------------

   overriding function Is_Global
     (E  : General_Entity) return Boolean is
   begin
      if Active (SQLITE) then
         return E.Db.Xref.Declaration (E.Entity).Flags.Is_Global;
      else
         return Old_Entities.Get_Attributes
           (E.Old_Entity)(Old_Entities.Global);
      end if;
   end Is_Global;

   ---------------------
   -- Is_Static_Local --
   ---------------------

   overriding function Is_Static_Local
     (E  : General_Entity) return Boolean is
   begin
      if Active (SQLITE) then
         return E.Db.Xref.Declaration (E.Entity).Flags.Is_Static_Local;
      else
         return Old_Entities.Get_Attributes
           (E.Old_Entity)(Old_Entities.Static_Local);
      end if;
   end Is_Static_Local;

   -------------
   -- Is_Type --
   -------------

   overriding function Is_Type
     (E  : General_Entity) return Boolean
   is
      use Old_Entities;
   begin
      if Active (SQLITE) then
         return E.Db.Xref.Declaration (E.Entity).Flags.Is_Type;
      else
         return Old_Entities.Get_Category (E.Old_Entity) =
           Old_Entities.Type_Or_Subtype;
      end if;
   end Is_Type;

   -------------------------
   -- Is_Dispatching_Call --
   -------------------------

   function Is_Dispatching_Call
     (Db  : access General_Xref_Database_Record;
      Ref : General_Entity_Reference) return Boolean
   is
      use Old_Entities;
   begin
      if Active (SQLITE) then
         return Db.Xref.Is_Dispatching_Call (Ref.Ref);
      else
         return Old_Entities.Get_Kind (Ref.Old_Ref) =
           Old_Entities.Dispatching_Call;
      end if;
   end Is_Dispatching_Call;

   ------------
   -- At_End --
   ------------

   function At_End (Iter : Base_Entities_Cursor) return Boolean is
   begin
      if Active (SQLITE) then
         return not Has_Element (Iter.Iter);
      else
         raise Program_Error;
      end if;
   end At_End;

   ---------
   -- Get --
   ---------

   function Get (Iter : Base_Entities_Cursor) return Root_Entity'Class is
   begin
      if Active (SQLITE) then
         return General_Entity'
           (Entity => Element (Iter.Iter),
            Db     => Iter.Db,
            others => <>);
      else
         raise Program_Error;
      end if;
   end Get;

   ----------
   -- Next --
   ----------

   procedure Next (Iter : in out Base_Entities_Cursor) is
   begin
      if Active (SQLITE) then
         Next (Iter.Iter);
      else
         raise Program_Error;
      end if;
   end Next;

   -----------------------------
   -- Get_All_Called_Entities --
   -----------------------------

   overriding function Get_All_Called_Entities
     (Entity : General_Entity) return Calls_Iterator'Class
   is
      Result : Calls_Iterator;
   begin
      if Active (SQLITE) then
         Result.Db := Entity.Db;
         Entity.Db.Xref.Calls (Entity.Entity, Result.Iter);
      else
         Result.Old_Iter := Old_Entities.Queries.Get_All_Called_Entities
           (Entity.Old_Entity);
      end if;
      return Result;
   end Get_All_Called_Entities;

   ----------------------
   -- Entities_In_File --
   ----------------------

   function Entities_In_File
     (Self    : access General_Xref_Database_Record'Class;
      File    : GNATCOLL.VFS.Virtual_File;
      Project : GNATCOLL.Projects.Project_Type;
      Name    : String := "") return Entities_In_File_Cursor
   is
      Result  : Entities_In_File_Cursor;
      F       : Old_Entities.Source_File;
   begin
      Result.Db := General_Xref_Database (Self);

      if Active (SQLITE) then
         if Name = "" then
            Self.Xref.Referenced_In (File, Project, Cursor => Result.Iter);
         else
            Self.Xref.Referenced_In
              (File, Project, Name, Cursor => Result.Iter);
         end if;

      else
         F := Old_Entities.Get_Or_Create
           (Self.Entities, File, Allow_Create => True);
         Old_Entities.Queries.Find_All_Entities_In_File
           (Iter        => Result.Old_Iter,
            File        => F,
            Name        => Name);
      end if;
      return Result;
   end Entities_In_File;

   ------------
   -- At_End --
   ------------

   overriding function At_End
     (Iter : Entities_In_File_Cursor) return Boolean is
   begin
      if Active (SQLITE) then
         return At_End (Base_Entities_Cursor (Iter));
      else
         return At_End (Iter.Old_Iter);
      end if;
   end At_End;

   ---------
   -- Get --
   ---------

   overriding function Get
     (Iter : Entities_In_File_Cursor) return Root_Entity'Class is
   begin
      if Active (SQLITE) then
         return Get (Base_Entities_Cursor (Iter));
      else
         return General_Entity'
           (Old_Entity => Get (Iter.Old_Iter),
            Db         => Iter.Db,
            others => <>);
      end if;
   end Get;

   ----------
   -- Next --
   ----------

   overriding procedure Next
     (Iter : in out Entities_In_File_Cursor) is
   begin
      if Active (SQLITE) then
         Next (Base_Entities_Cursor (Iter));
      else
         Next (Iter.Old_Iter);
      end if;
   end Next;

   ------------------------------
   -- All_Entities_From_Prefix --
   ------------------------------

   function All_Entities_From_Prefix
     (Self       : access General_Xref_Database_Record'Class;
      Prefix     : String;
      Is_Partial : Boolean := True) return Entities_In_Project_Cursor
   is
      use Old_Entities.Entities_Search_Tries;
      Result : Entities_In_Project_Cursor;
   begin
      Result.Db := General_Xref_Database (Self);
      if Active (SQLITE) then
         if Active (Me) then
            Increase_Indent (Me, "All_Entities from Prefix '" & Prefix
                             & "' partial=" & Is_Partial'Img);
         end if;

         Self.Xref.From_Prefix
           (Prefix     => Prefix,
            Is_Partial => Is_Partial,
            Cursor     => Result.Iter);

         Decrease_Indent (Me);
      else
         Result.Old_Iter :=
           Start (Trie     => Old_Entities.Get_Name_Index
                     (Old_Entities.Get_LI_Handler (Self.Entities)),
                  Prefix   => Prefix,
                  Is_Partial => Is_Partial);
      end if;
      return Result;
   end All_Entities_From_Prefix;

   -------------
   -- Destroy --
   -------------

   procedure Destroy (Iter : in out Entities_In_Project_Cursor) is
   begin
      if Active (SQLITE) then
         null;
      else
         Old_Entities.Entities_Search_Tries.Free (Iter.Old_Iter);
      end if;
   end Destroy;

   ------------
   -- At_End --
   ------------

   overriding function At_End
     (Iter : Entities_In_Project_Cursor) return Boolean
   is
      use Old_Entities.Entities_Search_Tries;
   begin
      if Active (SQLITE) then
         return not Has_Element (Iter.Iter);
      else
         return At_End (Iter.Old_Iter);
      end if;
   end At_End;

   ---------
   -- Get --
   ---------

   overriding function Get
     (Iter : Entities_In_Project_Cursor) return Root_Entity'Class
   is
      use Old_Entities.Entities_Search_Tries;
   begin
      if Active (SQLITE) then
         return From_New (Iter.Db, Element (Iter.Iter));
      else
         return From_Old (Get (Iter.Old_Iter));
      end if;
   end Get;

   ----------
   -- Next --
   ----------

   overriding procedure Next (Iter : in out Entities_In_Project_Cursor) is
      use Old_Entities.Entities_Search_Tries;
   begin
      if Active (SQLITE) then
         Next (Iter.Iter);
      else
         Next (Iter.Old_Iter);
      end if;
   end Next;

   ------------
   -- At_End --
   ------------

   overriding function At_End (Iter : Calls_Iterator) return Boolean is
   begin
      if Active (SQLITE) then
         return At_End (Base_Entities_Cursor (Iter));
      else
         return At_End (Iter.Old_Iter);
      end if;
   end At_End;

   ---------
   -- Get --
   ---------

   overriding function Get
     (Iter : Calls_Iterator) return Root_Entity'Class is
   begin
      if Active (SQLITE) then
         return Get (Base_Entities_Cursor (Iter));
      else
         return General_Entity'
           (Old_Entity => Get (Iter.Old_Iter),
            Db         => Iter.Db,
            others => <>);
      end if;
   end Get;

   ----------
   -- Next --
   ----------

   overriding procedure Next (Iter : in out Calls_Iterator) is
   begin
      if Active (SQLITE) then
         Next (Base_Entities_Cursor (Iter));
      else
         Next (Iter.Old_Iter);
      end if;
   end Next;

   -------------
   -- Destroy --
   -------------

   procedure Destroy (Iter : in out Calls_Iterator) is
   begin
      if not Active (SQLITE) then
         Destroy (Iter.Old_Iter);
      end if;
   end Destroy;

   ------------
   -- To_Old --
   ------------

   function To_Old
     (Entity : General_Entity) return Old_Entities.Entity_Information is
   begin
      return Entity.Old_Entity;
   end To_Old;

   function From_Old
     (Entity : Old_Entities.Entity_Information) return Root_Entity'Class is
   begin
      return General_Entity'(Old_Entity => Entity, others => <>);
   end From_Old;

   ------------
   -- To_New --
   ------------

--     function To_New
--       (Entity : General_Entity) return GNATCOLL.Xref.Entity_Information is
--     begin
--        return Entity.Entity;
--     end To_New;

   --------------
   -- From_New --
   --------------

   function From_New
     (Db     : General_Xref_Database;
      Entity : GNATCOLL.Xref.Entity_Information) return General_Entity is
   begin
      return (Entity => Entity, Db => Db, others => <>);
   end From_New;

   ----------------
   -- Parameters --
   ----------------

   overriding function Parameters
     (Entity : General_Entity) return Parameter_Array
   is
      All_Params : Parameter_Array (1 .. 100);
      Count      : Integer := All_Params'First - 1;
   begin
      if Active (SQLITE) then
         declare
            Curs : Parameters_Cursor :=
              Entity.Db.Xref.Parameters (Entity.Entity);
         begin
            while Curs.Has_Element loop
               Count := Count + 1;
               All_Params (Count) :=
                 (Kind => Curs.Element.Kind,
                  Parameter => From_New (Entity.Db, Curs.Element.Parameter));
               Curs.Next;
            end loop;
         end;

      else
         declare
            Iter : Old_Entities.Queries.Subprogram_Iterator :=
              Old_Entities.Queries.Get_Subprogram_Parameters
                (Entity.Old_Entity);
            E    : Old_Entities.Entity_Information;
         begin
            loop
               Old_Entities.Queries.Get (Iter, E);
               exit when E = null;

               Count := Count + 1;
               All_Params (Count).Parameter := General_Entity (From_Old (E));
               case Old_Entities.Queries.Get_Type (Iter) is
                  when Old_Entities.Queries.In_Parameter =>
                     All_Params (Count).Kind := In_Parameter;
                  when Old_Entities.Queries.Out_Parameter =>
                     All_Params (Count).Kind := Out_Parameter;
                  when Old_Entities.Queries.In_Out_Parameter =>
                     All_Params (Count).Kind := In_Out_Parameter;
                  when Old_Entities.Queries.Access_Parameter =>
                     All_Params (Count).Kind := Access_Parameter;
               end case;

               Old_Entities.Queries.Next (Iter);
            end loop;
         end;
      end if;

      return All_Params (All_Params'First .. Count);
   end Parameters;

   ---------------------
   -- Is_Parameter_Of --
   ---------------------

   overriding function Is_Parameter_Of
     (Entity : General_Entity) return Root_Entity'Class
   is
   begin
      if Active (SQLITE) then
         return From_New
           (Entity.Db, Entity.Db.Xref.Parameter_Of (Entity.Entity));
      else
         return From_Old
           (Old_Entities.Queries.Is_Parameter_Of (Entity.Old_Entity));
      end if;
   end Is_Parameter_Of;

   ---------------------
   -- Is_Primitive_Of --
   ---------------------

   overriding function Is_Primitive_Of
     (Entity : General_Entity) return Entity_Array
   is
      Result : Entity_Lists.List;
      Curs   : Entities_Cursor;
      E      : General_Entity;
   begin
      if Active (SQLITE) then
         Entity.Db.Xref.Method_Of (Entity.Entity, Curs);
         Fill_Entity_Array (Entity.Db, Curs, Result);
         return To_Entity_Array (Result);
      else
         E := General_Entity
           (From_Old
              (Old_Entities.Is_Primitive_Operation_Of (Entity.Old_Entity)));
         if E /= No_General_Entity then
            return (1 => new General_Entity'(E));
         else
            return (1 .. 0 => new General_Entity'(No_General_Entity));
         end if;
      end if;
   end Is_Primitive_Of;

   -------------------
   -- Is_Up_To_Date --
   -------------------

   function Is_Up_To_Date
     (Self : access General_Xref_Database_Record;
      File : Virtual_File) return Boolean
   is
      Source : Old_Entities.Source_File;
   begin
      if Active (SQLITE) then
         return Self.Xref.Is_Up_To_Date (File);
      else
         Source := Old_Entities.Get_Or_Create
           (Self.Entities, File, Allow_Create => True);
         return Old_Entities.Is_Up_To_Date (Source);
      end if;
   end Is_Up_To_Date;

   -----------------
   -- Has_Methods --
   -----------------

   overriding function Has_Methods
     (E  : General_Entity) return Boolean
   is
      use Old_Entities;
      K  : Old_Entities.E_Kinds;
   begin
      if Active (SQLITE) then
         if E.Entity /= No_Entity then
            return E.Db.Xref.Declaration (E.Entity).Flags.Has_Methods;
         end if;

      else
         if E.Old_Entity /= null then
            K := Old_Entities.Get_Kind (E.Old_Entity).Kind;
            return K = Old_Entities.Class
              or else K = Record_Kind
              or else K = Old_Entities.Interface_Kind;
         end if;
      end if;

      --  ??? Fallback on constructs
      return False;
   end Has_Methods;

   ---------------
   -- Is_Access --
   ---------------

   overriding function Is_Access
     (E  : General_Entity) return Boolean
   is
      use Old_Entities;
   begin
      if Active (SQLITE) then
         return E.Db.Xref.Declaration (E.Entity).Flags.Is_Access;

      else
         return E.Old_Entity /= null
           and then Old_Entities.Get_Kind (E.Old_Entity).Kind =
              Old_Entities.Access_Kind;
      end if;
   end Is_Access;

   -----------------
   -- Is_Abstract --
   -----------------

   overriding function Is_Abstract
     (E  : General_Entity) return Boolean
   is
   begin
      if Active (SQLITE) then
         return E.Db.Xref.Declaration (E.Entity).Flags.Is_Abstract;

      else
         return E.Old_Entity /= null
           and then Old_Entities.Get_Kind (E.Old_Entity).Is_Abstract;
      end if;
   end Is_Abstract;

   --------------
   -- Is_Array --
   --------------

   overriding function Is_Array
     (E  : General_Entity) return Boolean
   is
      use Old_Entities;
      Is_Array_E : constant array (E_Kinds) of Boolean :=
        (Overloaded_Entity => True,
         Unresolved_Entity => True,
         Array_Kind        => True,
         String_Kind       => True,
         others            => False);
   begin
      if Active (SQLITE) then
         return E.Db.Xref.Declaration (E.Entity).Flags.Is_Array;

      else
         return E.Old_Entity /= null
           and then Is_Array_E (Old_Entities.Get_Kind (E.Old_Entity).Kind);
      end if;
   end Is_Array;

   ------------------------------
   -- Is_Printable_In_Debugger --
   ------------------------------

   overriding function Is_Printable_In_Debugger
     (E  : General_Entity) return Boolean
   is
      use Old_Entities;
      Is_Printable_Entity : constant array (E_Kinds) of Boolean :=
        (Overloaded_Entity    => True,
         Unresolved_Entity    => True,
         Access_Kind          => True,
         Array_Kind           => True,
         Boolean_Kind         => True,
         Class_Wide           => True,
         Class                => True,
         Decimal_Fixed_Point  => True,
         Enumeration_Literal  => True,
         Enumeration_Kind     => True,
         Exception_Entity     => True,
         Floating_Point       => True,
         Modular_Integer      => True,
         Named_Number         => True,
         Ordinary_Fixed_Point => True,
         Record_Kind          => True,
         Signed_Integer       => True,
         String_Kind          => True,
         others               => False);

   begin
      if Active (SQLITE) then
         return E.Db.Xref.Declaration (E.Entity).Flags.Is_Printable_In_Gdb;

      else
         return E.Old_Entity /= null
           and then Is_Printable_Entity
             (Old_Entities.Get_Kind (E.Old_Entity).Kind);
      end if;
   end Is_Printable_In_Debugger;

   ----------------------
   -- Get_Display_Kind --
   ----------------------

   overriding function Get_Display_Kind
     (Entity : General_Entity) return String
   is
   begin
      if Active (SQLITE) then
         return To_String (Entity.Db.Xref.Declaration (Entity.Entity).Kind);
      else
         return Old_Entities.Kind_To_String
           (Old_Entities.Get_Kind (Entity.Old_Entity));
      end if;
   end Get_Display_Kind;

   ------------------------------
   -- Reference_Is_Declaration --
   ------------------------------

   function Reference_Is_Declaration
     (Db  : access General_Xref_Database_Record'Class;
      Ref : General_Entity_Reference) return Boolean is
      pragma Unreferenced (Db);
   begin
      if Active (SQLITE) then
         return Ref.Ref.Kind_Id = Kind_Id_Declaration;
      else
         return Old_Entities.Queries.Reference_Is_Declaration
           (Old_Entities.Get_Kind (Ref.Old_Ref));
      end if;
   end Reference_Is_Declaration;

   -----------------------
   -- Reference_Is_Body --
   -----------------------

   function Reference_Is_Body
     (Db  : access General_Xref_Database_Record'Class;
      Ref : General_Entity_Reference) return Boolean is
      pragma Unreferenced (Db);
   begin
      if Active (SQLITE) then
         return Ref.Ref.Kind = "body";
      else
         return Old_Entities.Queries.Reference_Is_Body
           (Old_Entities.Get_Kind (Ref.Old_Ref));
      end if;
   end Reference_Is_Body;

   -----------------------
   -- Is_Read_Reference --
   -----------------------

   function Is_Read_Reference
     (Db  : access General_Xref_Database_Record'Class;
      Ref : General_Entity_Reference) return Boolean is
   begin
      if Active (SQLITE) then
         return Db.Xref.Is_Read_Reference (Ref.Ref);
      else
         return Old_Entities.Is_Read_Reference
           (Old_Entities.Get_Kind (Ref.Old_Ref));
      end if;
   end Is_Read_Reference;

   --------------------------------------------
   -- Is_Or_Read_Write_Or_Implicit_Reference --
   --------------------------------------------

   function Is_Read_Or_Write_Or_Implicit_Reference
     (Db  : access General_Xref_Database_Record'Class;
      Ref : General_Entity_Reference) return Boolean
   is
   begin
      return Is_Read_Or_Write_Reference (Db, Ref)
        or else Is_Implicit_Reference (Db, Ref);
   end Is_Read_Or_Write_Or_Implicit_Reference;

   -----------------------------------
   -- Is_Read_Or_Implicit_Reference --
   -----------------------------------

   function Is_Read_Or_Implicit_Reference
     (Db  : access General_Xref_Database_Record'Class;
      Ref : General_Entity_Reference) return Boolean
   is
   begin
      return Is_Read_Reference (Db, Ref)
        or else Is_Implicit_Reference (Db, Ref);
   end Is_Read_Or_Implicit_Reference;

   ---------------------------
   -- Is_Implicit_Reference --
   ---------------------------

   function Is_Implicit_Reference
     (Db  : access General_Xref_Database_Record'Class;
      Ref : General_Entity_Reference) return Boolean
   is
      use Old_Entities;
   begin
      if Active (SQLITE) then
         return Db.Xref.Is_Implicit_Reference (Ref.Ref);
      else
         return Old_Entities.Get_Kind (Ref.Old_Ref) = Old_Entities.Implicit;
      end if;
   end Is_Implicit_Reference;

   -----------------------
   -- Is_Real_Reference --
   -----------------------

   function Is_Real_Reference
     (Db  : access General_Xref_Database_Record'Class;
      Ref : General_Entity_Reference) return Boolean is
   begin
      if Active (SQLITE) then
         return Db.Xref.Is_Real_Reference (Ref.Ref);
      else
         return Old_Entities.Is_Real_Reference
           (Old_Entities.Get_Kind (Ref.Old_Ref));
      end if;
   end Is_Real_Reference;

   -----------------------------------
   -- Is_Real_Or_Implicit_Reference --
   -----------------------------------

   function Is_Real_Or_Implicit_Reference
     (Db  : access General_Xref_Database_Record'Class;
      Ref : General_Entity_Reference) return Boolean is
   begin
      return Is_Real_Reference (Db, Ref)
        or else Is_Implicit_Reference (Db, Ref);
   end Is_Real_Or_Implicit_Reference;

   ------------------------
   -- Is_Write_Reference --
   ------------------------

   function Is_Write_Reference
     (Db  : access General_Xref_Database_Record'Class;
      Ref : General_Entity_Reference) return Boolean is
   begin
      if Active (SQLITE) then
         return Db.Xref.Is_Write_Reference (Ref.Ref);
      else
         return Old_Entities.Is_Write_Reference
           (Old_Entities.Get_Kind (Ref.Old_Ref));
      end if;
   end Is_Write_Reference;

   --------------------------------
   -- Is_Read_Or_Write_Reference --
   --------------------------------

   function Is_Read_Or_Write_Reference
     (Db  : access General_Xref_Database_Record'Class;
      Ref : General_Entity_Reference) return Boolean is
   begin
      if Active (SQLITE) then
         return Db.Xref.Is_Read_Or_Write_Reference (Ref.Ref);
      else
         return Old_Entities.Is_Write_Reference
           (Old_Entities.Get_Kind (Ref.Old_Ref))
           or else Old_Entities.Is_Read_Reference
             (Old_Entities.Get_Kind (Ref.Old_Ref));
      end if;
   end Is_Read_Or_Write_Reference;

   -------------------
   -- Open_Database --
   -------------------

   procedure Open_Database
     (Self   : General_Xref_Database; Tree   : Project_Tree_Access)
   is
      Working_Xref_File : Virtual_File;

      Error : GNAT.Strings.String_Access;
   begin
      Working_Xref_File := Xref_Database_Location (Self);

      Self.Xref_Db_Is_Temporary := Tree.Status /= From_File;

      Trace (Me, "Set up xref database: " &
             (+Working_Xref_File.Full_Name.all));

      Self.Xref.Setup_DB
        (DB    => GNATCOLL.SQL.Sqlite.Setup
           (Database => +Working_Xref_File.Full_Name.all,
            Errors   => Self.Errors),
         Tree  => Tree,
         Error => Error);

      --  Not interested in schema version errors, gnatinspect already
      --  displays them on the console
      Free (Error);
   end Open_Database;

   --------------------
   -- Close_Database --
   --------------------

   procedure Close_Database (Self   : General_Xref_Database) is
      Valgrind : GNAT.Strings.String_Access;
      Success : Boolean;
   begin
      if Active (SQLITE) then
         Trace (Me, "Closing xref database, temporary="
                & Self.Xref_Db_Is_Temporary'Img);
         Self.Xref.Free;

         --  If we were already working on a database, first copy the working
         --  database to the database saved between sessions, for future use

         if Self.Xref_Db_Is_Temporary then
            --  This database does not need saving, so we are deleting it
            Trace (Me, "Database was temporary, not saving");

            if Self.Working_Xref_Db /= No_File then
               Self.Working_Xref_Db.Delete (Success);

               if not Success then
                  Trace
                    (Me, "Warning: could not delete temporary database file");
               end if;
            end if;
         end if;

      else
         --  Most of the rest is for the sake of memory leaks checkin, and
         --  since it can take a while for big projects we do not do this
         --  in normal times.

         Valgrind := GNAT.OS_Lib.Getenv ("VALGRIND");
         if Valgrind.all /= ""
           and then Valgrind.all /= "no"
         then
            Old_Entities.Destroy (Self.Entities);
         end if;
         Free (Valgrind);
      end if;
   end Close_Database;

   -------------
   -- Destroy --
   -------------

   procedure Destroy (Self : in out General_Xref_Database) is
      procedure Unchecked_Free is new Ada.Unchecked_Deallocation
        (General_Xref_Database_Record'Class, General_Xref_Database);
   begin
      Close_Database (Self);
      Self.Xref := null;
      Free (Self.Constructs);
      Unchecked_Free (Self);
   end Destroy;

   ------------
   -- Freeze --
   ------------

   function Freeze
     (Self : access General_Xref_Database_Record) return Database_Lock is
   begin
      if Active (SQLITE) then
         Self.Freeze_Count := Self.Freeze_Count + 1;
         return No_Lock;
      else
         Old_Entities.Freeze (Self.Entities);
         return (Constructs =>
                   Old_Entities.Lock_Construct_Heuristics (Self.Entities));
      end if;
   end Freeze;

   ------------
   -- Frozen --
   ------------

   function Frozen
     (Self : access General_Xref_Database_Record) return Boolean
   is
      use Old_Entities;
   begin
      if Active (SQLITE) then
         return Self.Freeze_Count > 0;
      else
         return Old_Entities.Frozen (Self.Entities) /= Create_And_Update;
      end if;
   end Frozen;

   ----------
   -- Thaw --
   ----------

   procedure Thaw
     (Self : access General_Xref_Database_Record;
      Lock : in out Database_Lock) is
   begin
      if Active (SQLITE) then
         Self.Freeze_Count := Self.Freeze_Count - 1;
      else
         Old_Entities.Thaw (Self.Entities);
         Old_Entities.Unlock_Construct_Heuristics (Lock.Constructs);
      end if;
   end Thaw;

   ------------------
   -- End_Of_Scope --
   ------------------

   overriding function End_Of_Scope
     (Entity : General_Entity) return General_Location
   is
      Iter : References_Cursor;
      Ref  : Entity_Reference;
   begin
      if Active (SQLITE) then
         Entity.Db.Xref.References
           (Entity.Entity, Cursor => Iter,
            Include_Implicit => True,
            Include_All => True,
            Kinds       => "");

         while Has_Element (Iter) loop
            Ref := Element (Iter);
            if Ref.Is_End_Of_Scope then
               return (File    => Ref.File,
                       Project => Ref.Project,
                       Line    => Ref.Line,
                       Column  => Ref.Column);
            end if;

            Next (Iter);
         end loop;

      else
         declare
            use Old_Entities;
            Kind  : Old_Entities.Reference_Kind;
            Loc   : Old_Entities.File_Location;
         begin
            Old_Entities.Get_End_Of_Scope (Entity.Old_Entity, Loc, Kind);
            if Loc /= Old_Entities.No_File_Location then
               return (File    => Get_Filename (Loc.File),
                       Project => No_Project,  --  unknown
                       Line    => Get_Line (Loc),
                       Column  => Get_Column (Loc));
            end if;
         end;
      end if;
      return No_Location;
   end End_Of_Scope;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize
     (Self         : access General_Xref_Database_Record;
      Lang_Handler :
         access Language.Tree.Database.Abstract_Language_Handler_Record'Class;
      Symbols      : GNATCOLL.Symbols.Symbol_Table_Access;
      Registry     : Projects.Project_Registry_Access;
      Subprogram_Ref_Is_Call : Boolean := False;
      Errors       : access GNATCOLL.SQL.Exec.Error_Reporter'Class := null)
   is
      use Construct_Annotations_Pckg;
      LI_Entity_Key : Construct_Annotations_Pckg.Annotation_Key;
   begin
      Self.Constructs := new Language.Tree.Database.Construct_Database;
      Self.Lang_Handler := Abstract_Language_Handler (Lang_Handler);
      Set_Symbols (Self.Constructs, Symbols);

      Self.Symbols := Symbols;
      Self.Registry := Registry;
      Self.Errors := Errors;

      Language.Tree.Database.Initialize
        (Db         => Self.Constructs,
         Lg_Handler => Abstract_Language_Handler (Lang_Handler));
      Get_Annotation_Key
        (Get_Construct_Annotation_Key_Registry (Self.Constructs).all,
         LI_Entity_Key);

      Register_Assistant
        (Self.Constructs,
         LI_Assistant_Id,
         new LI_Db_Assistant'
           (Database_Assistant with
            LI_Key => LI_Entity_Key,
            Db     => General_Xref_Database (Self)));

      if Active (SQLITE) then
         if Self.Xref = null then
            Self.Xref := new Extended_Xref_Database;
         end if;

      else
         Self.Entities := Old_Entities.Create
           (Registry,
            Self.Constructs,
            Normal_Ref_In_Call_Graph => Subprogram_Ref_Is_Call);

         Old_Entities.Set_Symbols (Self.Entities, Symbols);
         Old_Entities.Register_Language_Handler (Self.Entities, Lang_Handler);
         Old_Entities.Set_LI_Handler
           (Self.Entities, ALI_Parser.Create_ALI_Handler
              (Db           => Self.Entities,
               Registry     => Registry.all,
               Lang_Handler => Lang_Handler));
      end if;
   end Initialize;

   ------------------
   -- To_LI_Entity --
   ------------------

   function To_LI_Entity
     (Self : access General_Xref_Database_Record'Class;
      E    : Entity_Access) return General_Entity
   is
      use Construct_Annotations_Pckg;
      Entity : General_Entity;

      Assistant : constant LI_Db_Assistant_Access := LI_Db_Assistant_Access
        (Get_Assistant (Self.Constructs, LI_Assistant_Id));

      Construct_Annotation : Construct_Annotations_Pckg.Annotation;
      Loc : General_Location;
   begin
      Get_Annotation
        (Get_Annotation_Container
           (Get_Tree (Get_File (E)), To_Construct_Tree_Iterator (E)).all,
         Assistant.LI_Key,
         Construct_Annotation);

      if Construct_Annotation = Construct_Annotations_Pckg.Null_Annotation then
         Loc := (File    => Get_File_Path (Get_File (E)),
                 Project => No_Project,   --  ??? unknown
                 Line    => Get_Construct (E).Sloc_Entity.Line,
                 Column  => To_Visible_Column
                  (Get_File (E),
                   Get_Construct (E).Sloc_Entity.Line,
                   String_Index_Type (Get_Construct (E).Sloc_Entity.Column)));

         --  Create a new LI entity

         if not Active (SQLITE) then
            declare
               use Old_Entities;
               New_Entity  : Old_Entities.Entity_Information;
               Declaration : Old_Entities.File_Location;
               K           : E_Kinds;
               Is_Type     : Boolean := False;
            begin
               Declaration :=
                 (Get_Or_Create
                    (Db  => Assistant.Db.Entities, File  => Loc.File),
                  Loc.Line,
                  Loc.Column);

               --  Make a simple association between construct categories
               --  and entity categories. This association is known to be
               --  inaccurate, but is helpful when trying to categorize
               --  entities.

               case Get_Construct (E).Category is
                  when Cat_Package | Cat_Namespace => K := Package_Kind;
                  when Cat_Task
                     | Cat_Procedure
                     | Cat_Function
                     | Cat_Method
                     | Cat_Constructor
                     | Cat_Destructor
                     | Cat_Protected
                     | Cat_Entry =>

                     K := Procedure_Kind;

                  when Cat_Class
                     | Cat_Structure
                     | Cat_Case_Inside_Record
                     | Cat_Union
                     | Cat_Type
                     | Cat_Subtype =>

                     K := Class;
                     Is_Type := True;

                  when Cat_Variable
                     | Cat_Local_Variable
                     | Cat_Parameter
                     | Cat_Discriminant
                     | Cat_Field =>

                     K := Signed_Integer;

                  when Cat_Literal =>

                     K := Enumeration_Literal;

                  when Cat_With
                     | Cat_Use
                     | Cat_Include =>

                     K := Include_File;

                  when Cat_Unknown
                     | Cat_Representation_Clause
                     | Cat_Loop_Statement
                     | Cat_If_Statement
                     | Cat_Case_Statement
                     | Cat_Select_Statement
                     | Cat_Accept_Statement
                     | Cat_Declare_Block
                     | Cat_Return_Block
                     | Cat_Simple_Block
                     | Cat_Exception_Handler
                     | Cat_Pragma
                     | Cat_Aspect
                     | Cat_Custom =>

                     K := Unresolved_Entity;
               end case;

               New_Entity := Old_Entities.Create_Dummy_Entity
                 (Name    => Get_Construct (E).Name,
                  Decl    => Declaration,
                  Kind    => K,
                  Is_Type => Is_Type);

               Entity := General_Entity (From_Old (New_Entity));
            end;

         else
            --  sqlite backend

            Entity := No_General_Entity;
         end if;

         Entity.Loc := Loc;
         Construct_Annotation := (Other_Kind, Other_Val => new LI_Annotation);
         LI_Annotation (Construct_Annotation.Other_Val.all).Entity := Entity;
         Set_Annotation
           (Get_Annotation_Container
              (Get_Tree (Get_File (E)), To_Construct_Tree_Iterator (E)).all,
            Assistant.LI_Key,
            Construct_Annotation);
      else
         null;
      end if;

      return LI_Annotation (Construct_Annotation.Other_Val.all).Entity;
   end To_LI_Entity;

   ----------
   -- Free --
   ----------

   overriding procedure Free (Obj : in out LI_Annotation) is
   begin
      Unref (Obj.Entity);
   end Free;

   ----------
   -- Hash --
   ----------

   overriding function Hash
     (Entity : General_Entity) return Integer is
   begin
      if Active (SQLITE) then
         --  Use directly the sqlite internal id.
         return GNATCOLL.Xref.Internal_Id (Entity.Entity);

      elsif Entity.Old_Entity /= null then
         declare
            use Old_Entities;
            Loc : constant File_Location :=
              Get_Declaration_Of (Entity.Old_Entity);
         begin
            return Integer
              (Hash
                 (Get (Get_Name (Entity.Old_Entity)).all
                  & (+Full_Name (Get_Filename (Get_File (Loc))))
                  & Get_Line (Loc)'Img
                  & Get_Column (Loc)'Img));
         end;
      end if;

      return 0;
   end Hash;

   ---------
   -- Cmp --
   ---------

   function Cmp
     (Entity1, Entity2 : Root_Entity'Class) return Integer
   is
      Id1, Id2 : Integer;
   begin
      if not (Entity1 in General_Entity'Class
        and then Entity2 in General_Entity'Class)
      then
         --  Two entities are not generic entities: compare their name
         declare
            Name1 : constant String := Entity1.Get_Name;
            Name2 : constant String := Entity2.Get_Name;
         begin
            if Name1 < Name2 then
               return -1;
            elsif Name1 = Name2 then
               return 0;
            else
               return 1;
            end if;
         end;
      end if;

      if Active (SQLITE) then
         Id1 := GNATCOLL.Xref.Internal_Id (General_Entity (Entity1).Entity);
         Id2 := GNATCOLL.Xref.Internal_Id (General_Entity (Entity2).Entity);
         if Id1 < Id2 then
            return -1;
         elsif Id1 = Id2 then
            return 0;
         else
            return 1;
         end if;

      elsif Entity1 = No_Root_Entity then
         if Entity2 = No_Root_Entity then
            return 0;
         else
            return -1;
         end if;

      elsif Entity2 = No_Root_Entity then
         return 1;

      else
         declare
            Name1 : constant String := Get_Name (Entity1);
            Name2 : constant String := Get_Name (Entity2);
         begin
            if Name1 < Name2 then
               return -1;

            elsif Name1 = Name2 then
               declare
                  File1 : constant Virtual_File :=
                    Get_Declaration (General_Entity (Entity1)).Loc.File;
                  File2 : constant Virtual_File :=
                    Get_Declaration (General_Entity (Entity2)).Loc.File;
               begin
                  if File1 < File2 then
                     return -1;
                  elsif File1 = File2 then
                     return 0;
                  else
                     return 1;
                  end if;
               end;

            else
               return 1;
            end if;
         end;
      end if;
   end Cmp;

   -----------------
   -- Has_Element --
   -----------------

   function Has_Element (Iter : File_Iterator) return Boolean is
   begin
      if Active (SQLITE) then
         return Has_Element (Iter.Iter);
      else
         if Iter.Is_Ancestor then
            return not Old_Entities.Queries.At_End (Iter.Old_Ancestor_Iter);
         else
            return not Old_Entities.Queries.At_End (Iter.Old_Iter);
         end if;
      end if;
   end Has_Element;

   ----------
   -- Next --
   ----------

   procedure Next (Iter : in out File_Iterator) is
      use Old_Entities;
   begin
      if Active (SQLITE) then
         Next (Iter.Iter);
      else
         if Iter.Is_Ancestor then
            Old_Entities.Queries.Next (Iter.Old_Ancestor_Iter);
         else
            Old_Entities.Queries.Next (Iter.Old_Iter);
            while not Old_Entities.Queries.At_End (Iter.Old_Iter)
              and then
                (Get (Iter.Old_Iter) = null
                 or else not Old_Entities.Queries.Is_Explicit (Iter.Old_Iter))
            loop
               Old_Entities.Queries.Next (Iter.Old_Iter);
            end loop;
         end if;
      end if;
   end Next;

   -------------
   -- Element --
   -------------

   function Element (Iter : File_Iterator) return Virtual_File is
   begin
      if Active (SQLITE) then
         return Element (Iter.Iter);
      else
         if Iter.Is_Ancestor then
            return Old_Entities.Get_Filename
              (Old_Entities.Queries.Get (Iter.Old_Ancestor_Iter));
         else
            return Old_Entities.Get_Filename
              (Old_Entities.Queries.Get (Iter.Old_Iter));
         end if;
      end if;
   end Element;

   -------------
   -- Project --
   -------------

   function Project
     (Iter : File_Iterator;
      Tree : GNATCOLL.Projects.Project_Tree'Class)
      return GNATCOLL.Projects.Project_Type is
   begin
      if Active (SQLITE) then
         return Project (Iter.Iter, Tree);
      else
         --  aggregate projects not supported anyway
         return GNATCOLL.Projects.No_Project;
      end if;
   end Project;

   -------------
   -- Destroy --
   -------------

   procedure Destroy (Iter : in out File_Iterator) is
   begin
      if not Active (SQLITE) then
         if Iter.Is_Ancestor then
            Old_Entities.Queries.Destroy (Iter.Old_Ancestor_Iter);
         end if;
      end if;
   end Destroy;

   -------------
   -- Destroy --
   -------------

   procedure Destroy (Iter : in out File_Iterator_Access) is
      procedure Unchecked_Free is new Ada.Unchecked_Deallocation
        (File_Iterator'Class, File_Iterator_Access);
   begin
      if Iter /= null then
         Destroy (Iter.all);
         Unchecked_Free (Iter);
      end if;
   end Destroy;

   -----------------------
   -- Find_Dependencies --
   -----------------------

   function Find_Dependencies
     (Self    : access General_Xref_Database_Record'Class;
      File    : GNATCOLL.VFS.Virtual_File;
      Project : GNATCOLL.Projects.Project_Type) return File_Iterator
   is
      use Old_Entities;
      Iter    : File_Iterator;
   begin
      Iter.Is_Ancestor := False;

      if Active (SQLITE) then
         Iter.Iter := Self.Xref.Imports (File, Project);
      else
         Old_Entities.Queries.Find_Dependencies
           (Iter => Iter.Old_Iter,
            File => Old_Entities.Get_Or_Create
              (Self.Entities, File, Allow_Create => True));

         while not Old_Entities.Queries.At_End (Iter.Old_Iter)
           and then
             (Get (Iter.Old_Iter) = null
              or else not Old_Entities.Queries.Is_Explicit (Iter.Old_Iter))
         loop
            Old_Entities.Queries.Next (Iter.Old_Iter);
         end loop;
      end if;
      return Iter;
   end Find_Dependencies;

   --------------------------------
   -- Find_Ancestor_Dependencies --
   --------------------------------

   function Find_Ancestor_Dependencies
     (Self    : access General_Xref_Database_Record'Class;
      File    : GNATCOLL.VFS.Virtual_File;
      Project : GNATCOLL.Projects.Project_Type) return File_Iterator
   is
      use Old_Entities;
      Iter    : File_Iterator;
   begin
      Iter.Is_Ancestor := True;

      if Active (SQLITE) then
         Iter.Iter := Self.Xref.Imported_By (File, Project);
      else
         Old_Entities.Queries.Find_Ancestor_Dependencies
           (Iter               => Iter.Old_Ancestor_Iter,
            File               => Old_Entities.Get_Or_Create
              (Self.Entities, File, Allow_Create => True),
            Include_Self       => False,
            Single_Source_File => False);

         while not Old_Entities.Queries.At_End (Iter.Old_Ancestor_Iter)
           and then
             (Get (Iter.Old_Ancestor_Iter) = null
              or else
                not Old_Entities.Queries.Is_Explicit (Iter.Old_Ancestor_Iter))
         loop
            Old_Entities.Queries.Next (Iter.Old_Ancestor_Iter);
         end loop;
      end if;
      return Iter;
   end Find_Ancestor_Dependencies;

   ----------------------
   -- Get_Display_Kind --
   ----------------------

   function Get_Display_Kind
     (Ref  : General_Entity_Reference) return String is
   begin
      if Active (SQLITE) then
         return Ada.Strings.Unbounded.To_String (Ref.Ref.Kind);
      else
         return Old_Entities.Kind_To_String
           (Old_Entities.Get_Kind (Ref.Old_Ref));
      end if;
   end Get_Display_Kind;

   ------------------------------
   -- All_Real_Reference_Kinds --
   ------------------------------

   function All_Real_Reference_Kinds
     (Db  : access General_Xref_Database_Record)
      return GNAT.Strings.String_List
   is
      use Old_Entities;
   begin
      if Active (SQLITE) then
         return Db.Xref.All_Real_Reference_Kinds;
      else
         return Result : String_List
           (Reference_Kind'Pos (Reference_Kind'First) + 1 ..
              Reference_Kind'Pos (Reference_Kind'Last) + 1)
         do
            for R in Reference_Kind'Range loop
               Result (Reference_Kind'Pos (R) + 1) :=
                 new String'(Kind_To_String (R));
            end loop;
         end return;
      end if;
   end All_Real_Reference_Kinds;

   --------------
   -- Is_Fuzzy --
   --------------

   overriding function Is_Fuzzy (Entity : General_Entity) return Boolean is
   begin
      return Entity.Is_Fuzzy;
   end Is_Fuzzy;

   ---------------------
   -- From_Constructs --
   ---------------------

   function From_Constructs
     (Db  : General_Xref_Database;
      Entity : Language.Tree.Database.Entity_Access) return General_Entity
   is
      Loc : General_Location;
   begin
      Loc :=
        (File    => Get_File_Path (Get_File (Entity)),
         Project => No_Project,  --  ambiguous
         Line    => Get_Construct (Entity).Sloc_Entity.Line,
         Column  => To_Visible_Column
            (Get_File (Entity),
             Get_Construct (Entity).Sloc_Entity.Line,
             String_Index_Type (Get_Construct (Entity).Sloc_Entity.Column)));
      return (Loc => Loc, Db => Db, others => <>);
   end From_Constructs;

   -----------------
   -- Instance_Of --
   -----------------

   overriding function Instance_Of
      (Entity : General_Entity) return Root_Entity'Class
   is
   begin
      if Active (SQLITE) then
         return From_New
           (Entity.Db,
            Entity.Db.Xref.Instance_Of (Entity.Entity));
      else
         return From_Old
           (Old_Entities.Queries.Is_Instantiation_Of (Entity.Old_Entity));
      end if;
   end Instance_Of;

   --------------------
   -- From_Instances --
   --------------------

   function From_Instances
     (Self   : access General_Xref_Database_Record;
      Ref    : General_Entity_Reference) return Entity_Array
   is
   begin
      if Active (SQLITE) then
         declare
            R : constant GNATCOLL.Xref.Entity_Array :=
              Self.Xref.From_Instances (Ref.Ref);
            Result : Entity_Array (R'Range);
         begin
            for A in R'Range loop
               Result (A) := new General_Entity'
                 (From_New (General_Xref_Database (Self), R (A)));
            end loop;
            return Result;
         end;

      else
         declare
            use Old_Entities;
            Inst : constant Entity_Instantiation :=
              Old_Entities.From_Instantiation_At (Ref.Old_Ref);
            Current : Entity_Instantiation := Inst;
            Count : Natural := 0;
         begin
            while Current /= No_Instantiation loop
               Count := Count + 1;
               Current := Generic_Parent (Current);
            end loop;

            declare
               Result : Entity_Array (1 .. Count);
            begin
               Count := Result'First;
               Current := Inst;
               while Current /= No_Instantiation loop
                  Result (Count) := new General_Entity'
                    (General_Entity (From_Old (Get_Entity (Current))));
                  Count := Count + 1;
                  Current := Generic_Parent (Current);
               end loop;

               return Result;
            end;
         end;
      end if;
   end From_Instances;

   -----------------------
   -- Fill_Entity_Array --
   -----------------------

   procedure Fill_Entity_Array
     (Db   : General_Xref_Database;
      Curs : in out Entities_Cursor'Class;
      Arr  : in out Entity_Lists.List)
   is
   begin
      while Curs.Has_Element loop
         Arr.Append (From_New (Db, Curs.Element));
         Curs.Next;
      end loop;
   end Fill_Entity_Array;

   ---------------------
   -- To_Entity_Array --
   ---------------------

   function To_Entity_Array
     (Arr : Entity_Lists.List) return Entity_Array
   is
      Result : Entity_Array (1 .. Integer (Arr.Length));
      C      : Entity_Lists.Cursor := Arr.First;
   begin
      for R in Result'Range loop
         Result (R) := new General_Entity'(Element (C));
         Entity_Lists.Next (C);
      end loop;
      return Result;
   end To_Entity_Array;

   ---------------------
   -- Discriminant_Of --
   ---------------------

   overriding function Discriminant_Of
      (Entity            : General_Entity) return Root_Entity'Class
   is
   begin
      if Active (SQLITE) then
         return From_New
           (Entity.Db,
            Entity.Db.Xref.Discriminant_Of (Entity.Entity));
      else
         --  ??? Not implemented.
         --  Old_Entities.Queries.Is_Discriminant requires knowning the record
         --  itself before we event start.

         return No_General_Entity;
      end if;
   end Discriminant_Of;

   -------------------
   -- Discriminants --
   -------------------

   overriding function Discriminants
     (Entity : General_Entity) return Entity_Array
   is
      Arr : Entity_Lists.List;
   begin
      if Active (SQLITE) then
         declare
            Curs : Entities_Cursor;
         begin
            Entity.Db.Xref.Discriminants (Entity.Entity, Cursor => Curs);
            Fill_Entity_Array (Entity.Db, Curs, Arr);
         end;

      else
         declare
            Iter  : Old_Entities.Queries.Entity_Reference_Iterator;
            Discr : Old_Entities.Entity_Information;
         begin
            Old_Entities.Queries.Find_All_References
              (Iter, Entity.Old_Entity,
               Filter => (Old_Entities.Discriminant => True, others => False));

            while not At_End (Iter) loop
               Discr := Get_Entity (Iter);
               if Discr /= null then
                  Append (Arr, General_Entity (From_Old (Discr)));
               end if;

               Next (Iter);
            end loop;

            Destroy (Iter);
         end;
      end if;

      return To_Entity_Array (Arr);
   end Discriminants;

   -----------------------
   -- Formal_Parameters --
   -----------------------

   overriding function Formal_Parameters
      (Entity : General_Entity) return Entity_Array
   is
      use Old_Entities;
      Arr : Entity_Lists.List;
   begin
      if Active (SQLITE) then
         declare
            Curs : Entities_Cursor;
         begin
            Entity.Db.Xref.Formal_Parameters (Entity.Entity, Cursor => Curs);
            Fill_Entity_Array (Entity.Db, Curs, Arr);
         end;

      else
         declare
            Param : Old_Entities.Entity_Information;
            Iter  : Old_Entities.Queries.Generic_Iterator :=
              Get_Generic_Parameters (Entity.Old_Entity);
         begin
            loop
               Get (Iter, Param);
               exit when Param = null;

               Append (Arr, General_Entity (From_Old (Param)));
               Next (Iter);
            end loop;
         end;
      end if;

      return To_Entity_Array (Arr);
   end Formal_Parameters;

   --------------
   -- Literals --
   --------------

   overriding function Literals
     (Entity : General_Entity) return Entity_Array
   is
      use Old_Entities;
      Arr : Entity_Lists.List;
   begin
      if Active (Me) then
         Increase_Indent
           (Me, "Retrieving literals of " & Get_Name (Entity));
      end if;

      if Active (SQLITE) then
         declare
            Curs : Entities_Cursor;
         begin
            Entity.Db.Xref.Literals (Entity.Entity, Cursor => Curs);
            Fill_Entity_Array (Entity.Db, Curs, Arr);
         end;

      elsif Get_Kind (Entity.Old_Entity).Kind = Enumeration_Kind then
         declare
            Field : Old_Entities.Entity_Information;
            Iter  : Old_Entities.Queries.Calls_Iterator :=
              Get_All_Called_Entities (Entity.Old_Entity);
         begin
            while not At_End (Iter) loop
               Field := Get (Iter);

               if Active (Me) then
                  Trace
                    (Me, "Old: candidate: "
                     & Get_Name (From_Old (Field))
                     & " range="
                     & In_Range (Old_Entities.Get_Declaration_Of (Field),
                       Entity.Old_Entity)'Img
                     & " cat=" & Get_Category (Field)'Img);
               end if;

               if In_Range (Old_Entities.Get_Declaration_Of (Field),
                            Entity.Old_Entity)
                 and then Get_Category (Field) = Literal
               then
                  Append (Arr, General_Entity (From_Old (Field)));
               end if;

               Next (Iter);
            end loop;

            Destroy (Iter);
         end;
      end if;

      if Active (Me) then
         Decrease_Indent (Me);
      end if;

      return To_Entity_Array (Arr);
   end Literals;

   -----------------
   -- Child_Types --
   -----------------

   overriding function Child_Types
      (Entity    : General_Entity;
       Recursive : Boolean) return Entity_Array
   is
      use Old_Entities;
      Arr : Entity_Lists.List;
   begin
      if Active (SQLITE) then
         declare
            Curs : Entities_Cursor;
            Rec  : Recursive_Entities_Cursor;
         begin
            if Recursive then
               Entity.Db.Xref.Recursive
                 (Entity  => Entity.Entity,
                  Compute => GNATCOLL.Xref.Child_Types'Access,
                  Cursor  => Rec);
               Fill_Entity_Array (Entity.Db, Rec, Arr);
            else
               Entity.Db.Xref.Child_Types (Entity.Entity, Cursor => Curs);
               Fill_Entity_Array (Entity.Db, Curs, Arr);
            end if;
         end;

      else
         declare
            Children : Children_Iterator :=
              Get_Child_Types (Entity.Old_Entity, Recursive => Recursive);
         begin
            while not At_End (Children) loop
               if Get (Children) /= null then
                  Append (Arr, General_Entity (From_Old (Get (Children))));
               end if;
               Next (Children);
            end loop;
            Destroy (Children);
         end;
      end if;

      return To_Entity_Array (Arr);
   end Child_Types;

   ------------------
   -- Parent_Types --
   ------------------

   overriding function Parent_Types
      (Entity    : General_Entity;
       Recursive : Boolean) return Entity_Array
   is
      use Old_Entities;
      Arr : Entity_Lists.List;
   begin
      if Active (SQLITE) then
         declare
            Curs : Entities_Cursor;
            Rec  : Recursive_Entities_Cursor;
         begin
            if Recursive then
               Entity.Db.Xref.Recursive
                 (Entity  => Entity.Entity,
                  Compute => GNATCOLL.Xref.Parent_Types'Access,
                  Cursor  => Rec);
               Fill_Entity_Array (Entity.Db, Rec, Arr);
            else
               Entity.Db.Xref.Parent_Types (Entity.Entity, Cursor => Curs);
               Fill_Entity_Array (Entity.Db, Curs, Arr);
            end if;
         end;

      else
         declare
            Parents : constant Entity_Information_Array :=
              Get_Parent_Types (Entity.Old_Entity, Recursive);
         begin
            for P in Parents'Range loop
               Append (Arr, General_Entity (From_Old (Parents (P))));
            end loop;
         end;
      end if;

      return To_Entity_Array (Arr);
   end Parent_Types;

   ------------
   -- Fields --
   ------------

   overriding function Fields
      (Entity            : General_Entity) return Entity_Array
   is
      use Old_Entities;
      Arr : Entity_Lists.List;
   begin
      if Active (SQLITE) then
         declare
            Curs : Entities_Cursor;
         begin
            Entity.Db.Xref.Fields (Entity.Entity, Cursor => Curs);
            Fill_Entity_Array (Entity.Db, Curs, Arr);
         end;

      --  Ignore for enumerations
      elsif Get_Kind (Entity.Old_Entity).Kind /= Enumeration_Kind then
         declare
            Field : Old_Entities.Entity_Information;
            Iter  : Old_Entities.Queries.Calls_Iterator :=
              Get_All_Called_Entities (Entity.Old_Entity);
         begin
            while not At_End (Iter) loop
               Field := Get (Iter);

               --  Hide discriminants and subprograms (would happen in C++,
               --  but these are primitive operations in this case)

               if In_Range (Old_Entities.Get_Declaration_Of (Field),
                            Entity.Old_Entity)
                 and then not Is_Discriminant (Field, Entity.Old_Entity)
                 and then not Old_Entities.Is_Subprogram (Field)
                 and then Get_Category (Field) /= Type_Or_Subtype
               then
                  Append (Arr, General_Entity (From_Old (Field)));
               end if;

               Next (Iter);
            end loop;

            Destroy (Iter);
         end;
      end if;

      return To_Entity_Array (Arr);
   end Fields;

   -------------
   -- Methods --
   -------------

   overriding function Methods
      (Entity            : General_Entity;
       Include_Inherited : Boolean) return Entity_Array
   is
      Result : Entity_Lists.List;
      Curs   : Entities_Cursor;
   begin
      if Active (SQLITE) then
         Entity.Db.Xref.Methods
           (Entity.Entity,
            Cursor            => Curs,
            Include_Inherited => Include_Inherited);
         Fill_Entity_Array (Entity.Db, Curs, Result);
      else
         declare
            use Old_Entities;
            Prim : Primitive_Operations_Iterator;
         begin
            Find_All_Primitive_Operations
              (Iter              => Prim,
               Entity            => Entity.Old_Entity,
               Include_Inherited => Include_Inherited);

            while not At_End (Prim) loop
               Append (Result, General_Entity (From_Old (Get (Prim))));
               Next (Prim);
            end loop;

            Destroy (Prim);
         end;
      end if;

      return To_Entity_Array (Result);
   end Methods;

   --------------------
   -- Component_Type --
   --------------------

   overriding function Component_Type
      (Entity : General_Entity) return Root_Entity'Class
   is
   begin
      if Active (SQLITE) then
         return From_New
           (Entity.Db, Entity.Db.Xref.Component_Type (Entity.Entity));
      else
         return From_Old (Old_Entities.Queries.Array_Contents_Type
                            (Entity.Old_Entity));
      end if;
   end Component_Type;

   --------------------
   -- Parent_Package --
   --------------------

   overriding function Parent_Package
     (Entity : General_Entity) return Root_Entity'Class
   is
   begin
      if Active (SQLITE) then
         return From_New
           (Entity.Db, Entity.Db.Xref.Parent_Package (Entity.Entity));
      else
         return From_Old
           (Old_Entities.Queries.Get_Parent_Package (Entity.Old_Entity));
      end if;
   end Parent_Package;

   -----------------
   -- Index_Types --
   -----------------

   overriding function Index_Types
      (Entity : General_Entity) return Entity_Array
   is
   begin
      if Active (SQLITE) then
         declare
            Curs : Entities_Cursor;
            Arr  : Entity_Lists.List;
         begin
            Entity.Db.Xref.Index_Types (Entity.Entity, Cursor => Curs);
            Fill_Entity_Array (Entity.Db, Curs, Arr);

            return To_Entity_Array (Arr);
         end;
      else
         declare
            Indexes : constant Old_Entities.Entity_Information_Array :=
              Old_Entities.Queries.Array_Index_Types (Entity.Old_Entity);
            Result : Entity_Array (Indexes'Range);
         begin
            for R in Result'Range loop
               Result (R) := new General_Entity'
                 (General_Entity (From_Old (Indexes (R))));
            end loop;
            return Result;
         end;
      end if;
   end Index_Types;

   ---------------
   -- Overrides --
   ---------------

   overriding function Overrides
     (Entity : General_Entity) return Root_Entity'Class
   is
   begin
      if Active (SQLITE) then
         return From_New (Entity.Db, Entity.Db.Xref.Overrides (Entity.Entity));
      else
         return From_Old (Old_Entities.Queries.Overriden_Entity
                          (Entity.Old_Entity));
      end if;
   end Overrides;

   -------------------------------
   -- Select_Entity_Declaration --
   -------------------------------

   function Select_Entity_Declaration
     (Self    : access General_Xref_Database_Record;
      File    : GNATCOLL.VFS.Virtual_File;
      Project : Project_Type;
      Entity  : Root_Entity'Class) return Root_Entity'Class
   is
      pragma Unreferenced (Self, File, Project);
   begin
      return Entity;
   end Select_Entity_Declaration;

   -----------
   -- Reset --
   -----------

   procedure Reset (Self : access General_Xref_Database_Record) is
   begin
      if not Active (SQLITE) then
         Old_Entities.Reset (Self.Entities);
      end if;
   end Reset;

   --------------------------
   -- Get_Entity_Reference --
   --------------------------

   function Get_Entity_Reference
     (Old_Ref : Old_Entities.Entity_Reference) return General_Entity_Reference
   is
      GER : constant General_Entity_Reference :=
        (Old_Ref => Old_Ref,
         Db  => null,
         Ref => No_Entity_Reference);
   begin
      return GER;
   end Get_Entity_Reference;

   ---------------------
   -- Project_Changed --
   ---------------------

   procedure Project_Changed (Self : General_Xref_Database) is
      Error : GNAT.Strings.String_Access;
   begin
      if Active (SQLITE) then
         --  Create an initial empty database. It will never be filled, and
         --  will be shortly replaced in Project_View_Changed, but it ensures
         --  that GPS does not raise exceptions if some action is performed
         --  while the project has not been computed (like loading of the
         --  desktop for instance).
         --  ??? We really should not be doing anything until the project has
         --  been computed.

         if Self.Xref /= null then
            Trace (Me, "Closing previous version of the database");
            Close_Database (Self);
         end if;

         Trace (Me, "Set up xref database: :memory:");
         Self.Working_Xref_Db := GNATCOLL.VFS.No_File;
         Self.Xref_Db_Is_Temporary := True;
         Self.Xref.Setup_DB
           (DB    => GNATCOLL.SQL.Sqlite.Setup
              (Database => ":memory:",
               Errors   => Self.Errors),
            Tree  => Self.Registry.Tree,
            Error => Error);

         --  not interested in schema version errors, gnatinspect will
         --  already display those for the user.
         Free (Error);
      else
         --  When loading a new project, we need to reset the cache containing
         --  LI information, otherwise this cache might contain dangling
         --  references to projects that have been freed. Recompute_View does
         --  something similar but tries to limit the files that are reset, so
         --  the calls below will just speed up the processing in
         --  Recompute_View when a new project is loaded.

         Old_Entities.Reset (Self.Entities);
      end if;
   end Project_Changed;

   ----------------------------
   -- Xref_Database_Location --
   ----------------------------

   function Xref_Database_Location
     (Self    : not null access General_Xref_Database_Record)
      return GNATCOLL.VFS.Virtual_File
   is
      Dir  : Virtual_File;
   begin
      if Active (SQLITE)
        and then Self.Working_Xref_Db = GNATCOLL.VFS.No_File
      then
         declare
            Project : constant Project_Type := Self.Registry.Tree.Root_Project;
            Attr : constant String :=
              Project.Attribute_Value
                (Build ("IDE", "Xref_Database"),
                 Default => "",
                 Use_Extended => True);
         begin
            if Attr = "" then
               declare
                  Hash : constant String := GNAT.SHA1.Digest
                    (+Project.Project_Path.Full_Name (Normalize => True));
               begin
                  Dir    := Project.Object_Dir;

                  if Dir = No_File then
                     Trace (Me, "Object_Dir is unknown for the root project "
                            & Project.Project_Path.Display_Full_Name);
                     Dir := GNATCOLL.VFS.Get_Current_Dir;
                  end if;

                  Self.Working_Xref_Db := Create_From_Dir
                    (Dir  => Get_Tmp_Directory,
                     Base_Name => +("gnatinspect-" & Hash & ".db"));
               end;
            else
               Self.Working_Xref_Db := Create_From_Base
                 (Base_Name => +Attr,
                  Base_Dir  => Project.Project_Path.Dir_Name);
            end if;

            Trace
              (Me, "project db file: " &
                 Self.Working_Xref_Db.Display_Full_Name);
         end;
      end if;

      return Self.Working_Xref_Db;
   end Xref_Database_Location;

   --------------------------
   -- Project_View_Changed --
   --------------------------

   procedure Project_View_Changed
     (Self   : General_Xref_Database;
      Tree   : Project_Tree_Access)
   is

      procedure Reset_File_If_External (S : in out Old_Entities.Source_File);
      --  Reset the xref info for a source file that no longer belongs to the
      --  project.

      ----------------------------
      -- Reset_File_If_External --
      ----------------------------

      procedure Reset_File_If_External (S : in out Old_Entities.Source_File) is
         --  old xref engine does not support aggregate project, so take the
         --  first possible match
         Info : constant File_Info :=
           Tree.Info_Set (Old_Entities.Get_Filename (S)).First_Element.all;
      begin
         if Info.Project = No_Project then
            Old_Entities.Reset (S);
         end if;
      end Reset_File_If_External;

   begin
      if Active (SQLITE) then

         if Self.Xref /= null then
            Trace (Me, "Closing previous version of the database");
            Close_Database (Self);
         end if;

         --  Self.Xref was initialized in Project_Changed.
         Self.Xref.Free;

         Open_Database (Self, Tree);

         --  ??? Now would be a good opportunity to update the cross-references
         --  rather than wait for the next compilation.

      else
         --  The list of source or ALI files might have changed, so we need to
         --  reset the cache containing LI information, otherwise this cache
         --  might contain dangling references to projects that have been
         --  freed. We used to do this only when loading a new project, but
         --  in fact that is not sufficient: when we look up xref info for a
         --  source file, if we haven't reset the cache we might get a reply
         --  pointing to a source file in a directory that is no longer part
         --  of the project in the new scenario.
         --
         --  In fact, we only reset the info for those source files that are no
         --  longer part of the project. This might take longer than dropping
         --  the whole database since in the former case we need to properly
         --  handle refcounting whereas Reset takes a shortcut. It is still
         --  probably cleaner to only reset what's needed.

         Old_Entities.Foreach_Source_File
           (Self.Entities, Reset_File_If_External'Access);
      end if;
   end Project_View_Changed;

   ----------
   -- Free --
   ----------

   procedure Free (X : in out Entity_Array) is
      procedure Unchecked_Free is new Ada.Unchecked_Deallocation
        (Root_Entity'Class, Root_Entity_Access);
   begin
      for J in X'Range loop
         Unchecked_Free (X (J));
      end loop;
   end Free;

end Xref;
