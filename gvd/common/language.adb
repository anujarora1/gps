-----------------------------------------------------------------------
--                   GVD - The GNU Visual Debugger                   --
--                                                                   --
--                      Copyright (C) 2000-2003                      --
--                              ACT-Europe                           --
--                                                                   --
-- GVD is free  software;  you can redistribute it and/or modify  it --
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

with Ada.Unchecked_Deallocation;
with Basic_Types;                 use Basic_Types;
with GNAT.Regpat;                 use GNAT.Regpat;
with GNAT.OS_Lib;
with GNAT.IO;                     use GNAT.IO;
with Odd_Intl;                    use Odd_Intl;
with String_Utils;                use String_Utils;
with Ada.Exceptions;              use Ada.Exceptions;
with Glib.Unicode;                use Glib, Glib.Unicode;

package body Language is

   ---------------------------
   -- Can_Tooltip_On_Entity --
   ---------------------------

   function Can_Tooltip_On_Entity
     (Lang   : access Language_Root;
      Entity : String) return Boolean
   is
      pragma Unreferenced (Lang, Entity);
   begin
      return True;
   end Can_Tooltip_On_Entity;

   ----------------------
   -- Explorer_Regexps --
   ----------------------

   function Explorer_Regexps
     (Lang : access Language_Root) return Explorer_Categories
   is
      pragma Unreferenced (Lang);
      E : Explorer_Categories (1 .. 0);
   begin
      return E;
   end Explorer_Regexps;

   ----------
   -- Free --
   ----------

   procedure Free (Lang : in out Language_Access) is
      procedure Internal is new Ada.Unchecked_Deallocation
        (Language_Root'Class, Language_Access);
   begin
      Internal (Lang);
   end Free;

   procedure Free (List : in out Construct_List) is
      Info, Tmp : Construct_Access;

      procedure Free is new
        Ada.Unchecked_Deallocation (Construct_Information, Construct_Access);

   begin
      Info := List.First;

      loop
         exit when Info = null;

         Free (Info.Name);
         Free (Info.Profile);
         Tmp := Info;
         Info := Info.Next;
         Free (Tmp);
      end loop;

      List.First   := null;
      List.Current := null;
      List.Last    := null;
   end Free;

   --------------------
   -- Is_System_File --
   --------------------

   function Is_System_File
     (Lang      : access Language_Root;
      File_Name : String) return Boolean
   is
      pragma Unreferenced (Lang, File_Name);
   begin
      return False;
   end Is_System_File;

   ----------------
   -- Looking_At --
   ----------------

   procedure Looking_At
     (Lang      : access Language_Root;
      Buffer    : String;
      Entity    : out Language_Entity;
      Next_Char : out Positive)
   is
      Matched : Match_Array (0 .. 1);
      Context : constant Language_Context :=
        Get_Language_Context (Language_Access (Lang));
      Keys : constant Pattern_Matcher := Keywords (Language_Access (Lang));
      Comm1, Comm2 : Character;
      C : Gunichar;

   begin
      --  Do we have a comment ?

      if Context.Comment_Start_Length /= 0
        and then Buffer'Length > Context.Comment_Start_Length
        and then Buffer
          (Buffer'First .. Buffer'First + Context.Comment_Start_Length - 1)
           = Context.Comment_Start
      then
         Entity := Comment_Text;
         Next_Char := Buffer'First + Context.Comment_Start_Length;

         while Next_Char + Context.Comment_End_Length - 1 <= Buffer'Last
           and then Buffer
           (Next_Char .. Next_Char + Context.Comment_End_Length - 1)
           /= Context.Comment_End
         loop
            Next_Char := UTF8_Find_Next_Char (Buffer, Next_Char);
         end loop;

         Next_Char := Next_Char + Context.Comment_End_Length;
         return;
      end if;

      --  Do we have a comment that end on newline ?

      if Context.New_Line_Comment_Start_Length /= 0
        and then Buffer'Length > Context.New_Line_Comment_Start_Length
        and then Buffer
        (Buffer'First .. Buffer'First
         + Context.New_Line_Comment_Start_Length - 1)
        = Context.New_Line_Comment_Start
      then
         Entity := Comment_Text;
         Next_Char := Buffer'First + Context.New_Line_Comment_Start_Length;

         while Next_Char <= Buffer'Last
           and then Buffer (Next_Char) /= ASCII.LF
         loop
            Next_Char := UTF8_Find_Next_Char (Buffer, Next_Char);
         end loop;

         return;
      end if;

      --  Do we have a string ?
      --  Note that we consider that strings never span over multiple lines...

      if Buffer (Buffer'First) = Context.String_Delimiter then
         Entity := String_Text;
         Next_Char := Buffer'First;

         loop
            Next_Char := Next_Char + 1;
            exit when Next_Char >= Buffer'Last
              or else Buffer (Next_Char) = ASCII.LF
              or else
                (Buffer (Next_Char) = Context.String_Delimiter
                   and then
                     (Context.Quote_Character = ASCII.NUL
                        or else
                          Buffer (Next_Char - 1) /= Context.Quote_Character));
         end loop;

         Next_Char := UTF8_Find_Next_Char (Buffer, Next_Char);
         return;
      end if;

      --  A protected constant character
      --  ??? The following test still does not handle cases such as
      --  '\012' for instance, or multi-byte character constants.

      if Buffer'Length > 4
        and then Buffer (Buffer'First) = Context.Constant_Character
        and then Buffer (Buffer'First + 1) = Context.Quote_Character
        and then Buffer (Buffer'First + 3) = Context.Constant_Character
      then
         Entity := Character_Text;
         Next_Char := Buffer'First + 4;
         return;
      end if;

      --  A constant character

      if Buffer'Length > 3
        and then Buffer (Buffer'First) = Context.Constant_Character
        and then Buffer (Buffer'First + 2) = Context.Constant_Character
      then
         Entity := Character_Text;
         Next_Char := Buffer'First + 3;
         return;
      end if;

      --  Do we have a keyword ?

      Match (Keys, Buffer, Matched);

      if Matched (0) /= No_Match then
         Next_Char := UTF8_Find_Next_Char (Buffer, Matched (0).Last);
         Entity := Keyword_Text;
         return;
      end if;

      --  Another special character, not part of a word: just skip it, before
      --  doing some regexp matching
      --  It is better to return a pointer to the newline, so that the icons
      --  on the side might be displayed properly.

      if not Is_Entity_Letter (UTF8_Get_Char (Buffer)) then
         Entity := Normal_Text;
         Next_Char := UTF8_Find_Next_Char (Buffer, Buffer'First);

         Comm1 := ASCII.LF;
         Comm2 := ASCII.LF;

         if Context.Comment_Start_Length /= 0 then
            Comm1 := Context.Comment_Start (Context.Comment_Start'First);
         end if;

         if Context.New_Line_Comment_Start_Length /= 0 then
            Comm2 :=
              Context.New_Line_Comment_Start (Context.Comment_Start'First);
         end if;

         while Next_Char <= Buffer'Last loop
            C := UTF8_Get_Char (Buffer (Next_Char .. Buffer'Last));

            exit when C = Character'Pos (ASCII.LF)
              or else C = Character'Pos (ASCII.HT)
              or else C = Character'Pos (Context.String_Delimiter)
              or else C = Character'Pos (Comm1)
              or else C = Character'Pos (Comm2)
              or else C = Character'Pos (Context.Constant_Character)
              or else Is_Alpha (C);

            Next_Char := UTF8_Find_Next_Char (Buffer, Next_Char);
         end loop;

         return;
      end if;

      --  Skip to the next meaningful character. we know we are
      --  starting with a letter

      Next_Char := UTF8_Find_Next_Char (Buffer, Buffer'First);
      Entity := Normal_Text;

      --  Skip the current word

      while Next_Char <= Buffer'Last
        and then Is_Entity_Letter
          (UTF8_Get_Char (Buffer (Next_Char .. Buffer'Last)))
      loop
         Next_Char := UTF8_Find_Next_Char (Buffer, Next_Char);
      end loop;
   end Looking_At;

   -------------------
   -- Format_Source --
   -------------------

   procedure Format_Source
     (Lang             : access Language_Root;
      Buffer           : String;
      Indent_Params    : Indent_Parameters := Default_Indent_Parameters;
      Reserved_Casing  : Casing_Type       := Lower;
      Ident_Casing     : Casing_Type       := Mixed;
      Format_Operators : Boolean           := True)
   is
      pragma Unreferenced (Lang, Indent_Params, Reserved_Casing,
                           Ident_Casing, Format_Operators);
   begin
      Put (Buffer);
   end Format_Source;

   ------------------
   -- Comment_Line --
   ------------------

   function Comment_Line
     (Lang : access Language_Root;
      Line : String) return String
   is
      pragma Unreferenced (Lang);
   begin
      return Line;
   end Comment_Line;

   --------------------
   -- Uncomment_Line --
   --------------------

   function Uncomment_Line
     (Lang : access Language_Root;
      Line : String) return String
   is
      pragma Unreferenced (Lang);
   begin
      return Line;
   end Uncomment_Line;

   ----------------------
   -- Parse_Constructs --
   ----------------------

   procedure Parse_Constructs
     (Lang          : access Language_Root;
      Buffer        : String;
      Result        : out Construct_List)
   is
      Matches        : Match_Array (0 .. 10);
      Categories     : constant Explorer_Categories :=
        Explorer_Regexps (Language_Access (Lang));
      First          : Natural;
      Line           : Natural;
      Line_Pos       : Natural;
      Sloc_Entity    : Source_Location;
      Sloc_Start     : Source_Location;
      Sloc_End       : Source_Location;
      Info           : Construct_Access;
      Match_Index    : Natural;

      procedure Forward
        (Index : Natural;
         Sloc  : in out Source_Location);
      --  Compute Line and Column fields in Sloc and update Line and Line_Pos

      procedure Forward
        (Index : Natural;
         Sloc  : in out Source_Location) is
      begin
         for J in Index .. Sloc.Index loop
            if Buffer (J) = ASCII.LF then
               Line     := Line + 1;
               Line_Pos := J;
            end if;
         end loop;

         Sloc.Line   := Line;
         Sloc.Column := Sloc.Index - Line_Pos;
      end Forward;

   begin
      Result := (null, null, null);

      --  For each category, parse the buffer

      for C in Categories'Range loop
         First    := Buffer'First;
         Line     := 1;
         Line_Pos := 0;

         loop
            Match (Categories (C).Regexp.all,
                   Buffer (First .. Buffer'Last),
                   Matches);

            exit when Matches (0) = No_Match;

            Match_Index := Categories (C).Position_Index;

            if Matches (Match_Index) /= No_Match then
               Sloc_Start.Index  := Matches (0).First;
               Sloc_Entity.Index := Matches (Match_Index).First;
               Sloc_End.Index    := Matches (0).Last;

               Forward (First, Sloc_Start);
               Forward (Sloc_Start.Index + 1, Sloc_Entity);
               Forward (Sloc_Entity.Index + 1, Sloc_End);

               Info           := Result.Current;
               Result.Current := new Construct_Information;

               if Result.First = null then
                  Result.First := Result.Current;
               else
                  Result.Current.Prev := Info;
                  Result.Current.Next := Info.Next;
                  Info.Next           := Result.Current;
               end if;

               Result.Last := Result.Current;
               Result.Current.Category := Categories (C).Category;

               if Categories (C).Make_Entry /= null then
                  Result.Current.Name := new String'
                    (Categories (C).Make_Entry (Buffer, Matches));
               else
                  Result.Current.Name := new String'
                    (Buffer (Matches (Match_Index).First ..
                             Matches (Match_Index).Last));
               end if;

               --  Result.Current.Profile := ???

               Result.Current.Sloc_Entity    := Sloc_Entity;
               Result.Current.Sloc_Start     := Sloc_Start;
               Result.Current.Sloc_End       := Sloc_End;
               Result.Current.Is_Declaration := False;
            end if;

            First := Matches (0).Last + 1;
         end loop;
      end loop;
   end Parse_Constructs;

   -----------------------------
   --  Parse_File_Constructs  --
   -----------------------------

   procedure Parse_File_Constructs
     (Lang      : access Language_Root'Class;
      File_Name : VFS.Virtual_File;
      Result    : out Construct_List)
   is
      use GNAT.OS_Lib;

      Buffer : GNAT.OS_Lib.String_Access;
   begin
      Buffer := VFS.Read_File (File_Name);

      if Buffer /= null then
         Parse_Constructs (Lang, Buffer.all, Result);
         Free (Buffer);
      end if;

   exception
      when E : others =>
         Put_Line ("Unexpected exception: " & Exception_Information (E));
         Free (Buffer);
   end Parse_File_Constructs;

   --------------------
   -- Parse_Entities --
   --------------------

   procedure Parse_Entities
     (Lang     : access Language_Root;
      Buffer   : String;
      Callback : Entity_Callback)
   is
      Index     : Natural := Buffer'First;
      Next_Char : Natural;
      End_Char  : Natural;
      Entity    : Language_Entity;

   begin
      loop
         exit when Index >= Buffer'Last;

         Looking_At (Lang, Buffer (Index .. Buffer'Last), Entity, Next_Char);

         if Next_Char = Buffer'Last then
            End_Char := Buffer'Last;
         else
            End_Char := Next_Char - 1;
         end if;

         exit when Callback
           (Entity,
            (0, 0, Index),
            (0, 0, End_Char),
            Entity = Comment_Text and then Next_Char > Buffer'Last);

         Index := Next_Char;
      end loop;
   end Parse_Entities;

   ----------------------
   -- Next_Indentation --
   ----------------------

   procedure Next_Indentation
     (Lang          : access Language_Root;
      Buffer        : String;
      Indent        : out Natural;
      Next_Indent   : out Natural;
      Indent_Params : Indent_Parameters := Default_Indent_Parameters)
   is
      pragma Unreferenced (Lang);

      Tab_Width : Natural renames Indent_Params.Tab_Width;
      Index     : Natural;

   begin
      if Buffer'Length = 0 then
         Indent := 0;
         Next_Indent := 0;
         return;
      end if;

      Index  := Buffer'Last - 1;
      Indent := 0;

      while Index > Buffer'First and then Buffer (Index - 1) /= ASCII.LF loop
         Index := Index - 1;
      end loop;

      loop
         if Buffer (Index) = ' ' then
            Indent := Indent + 1;
         elsif Buffer (Index) = ASCII.HT then
            Indent := Indent + Tab_Width - (Indent mod Tab_Width);
         else
            exit;
         end if;

         exit when Index = Buffer'Last;

         Index := Index + 1;
      end loop;

      Next_Indent := Indent;
   end Next_Indentation;

   -------------------
   -- Category_Name --
   -------------------

   function Category_Name (Category : Language_Category) return String is
   begin
      case Category is
         when Cat_Unknown               => return "";
         when Cat_Package               => return -"package";
         when Cat_Namespace             => return -"namespace";
         when Cat_Task                  => return -"task";
         when Cat_Procedure             => return -"subprogram";
         when Cat_Function              => return -"subprogram";
         when Cat_Method                => return -"method";
         when Cat_Constructor           => return -"constructor";
         when Cat_Destructor            => return -"destructor";
         when Cat_Protected             => return -"protected";
         when Cat_Entry                 => return -"entry";
         when Cat_Class                 => return -"class";
         when Cat_Structure             => return -"structure";
         when Cat_Union                 => return -"union";
         when Cat_Type                  => return -"type";
         when Cat_Subtype               => return -"subtype";
         when Cat_Variable              => return -"variable";
         when Cat_Local_Variable        => return -"variable";
         when Cat_Parameter             => return -"parameter";
         when Cat_Literal               => return -"literal";
         when Cat_Representation_Clause => return -"representation clause";
         when Cat_With                  => return -"with";
         when Cat_Use                   => return -"use";
         when Cat_Include               => return -"include";
         when Cat_Loop_Statement        => return "";
         when Cat_If_Statement          => return "";
         when Cat_Case_Statement        => return "";
         when Cat_Select_Statement      => return "";
         when Cat_Accept_Statement      => return "";
         when Cat_Declare_Block         => return "";
         when Cat_Simple_Block          => return "";
         when Cat_Exception_Handler     => return "";
      end case;
   end Category_Name;

   --------------------------------
   -- Get_Indentation_Parameters --
   --------------------------------

   procedure Get_Indentation_Parameters
     (Lang         : access Language_Root;
      Use_Tabs     : out Boolean;
      Params       : out Indent_Parameters;
      Indent_Style : out Indentation_Kind) is
   begin
      Use_Tabs     := Lang.Use_Tabs;
      Params       := Lang.Indent_Params;
      Indent_Style := Lang.Indent_Style;
   end Get_Indentation_Parameters;

   --------------------------------
   -- Set_Indentation_Parameters --
   --------------------------------

   procedure Set_Indentation_Parameters
     (Lang         : access Language_Root;
      Use_Tabs     : Boolean;
      Params       : Indent_Parameters;
      Indent_Style : Indentation_Kind) is
   begin
      Lang.Use_Tabs      := Use_Tabs;
      Lang.Indent_Params := Params;
      Lang.Indent_Style  := Indent_Style;
   end Set_Indentation_Parameters;

   ----------
   -- Free --
   ----------

   procedure Free (Fields : in out Project_Field_Array) is
   begin
      for F in Fields'Range loop
         Free (Fields (F).Attribute_Name);
         Free (Fields (F).Attribute_Index);
         Free (Fields (F).Description);
      end loop;
   end Free;

end Language;
