with String_Utils;            use String_Utils;
with Ada.Characters.Handling; use Ada.Characters.Handling;
with Ada.Text_IO;             use Ada.Text_IO;
with GNAT.OS_Lib;             use GNAT.OS_Lib;
with Scans;                   use Scans;
with Ada.Unchecked_Deallocation;
with Generic_Stack;

package body Source_Analyzer is

   ---------------
   -- Constants --
   ---------------

   None   : constant := -1;
   Spaces : constant String (1 .. 256) := (others => ' ');
   --  Use to handle indentation in procedure Do_Indent below.

   -----------
   -- Types --
   -----------

   Max_Identifier : constant := 256;
   --  Maximum length of an identifier.

   type Extended_Token is record
      Token       : Token_Type := No_Token;
      --  Enclosing token

      Declaration : Boolean := False;
      --  Are we inside a declarative part ?

      Identifier  : String (1 .. Max_Identifier);
      --  Name of the enclosing token
      --  The actual name is Identifier (1 .. Ident_Len)

      Ident_Len   : Natural := 0;
      --  Actual length of Indentifier
   end record;

   package Token_Stack is new Generic_Stack (Extended_Token);
   use Token_Stack;

   package Indent_Stack is new Generic_Stack (Integer);
   use Indent_Stack;

   --------------------------
   -- Line Buffer Handling --
   --------------------------

   --  The line buffer represents a buffer (e.g contents of a file) line
   --  by line. Line separators (LF or CR/LF) are kept at the end of the buffer
   --  It is recommended to take advantage of the bound information that comes
   --  with a String_Access so that there can be a direct mapping between
   --  the original raw buffer and a line buffer.
   --  Len is used to keep the length of the original line stored. Since this
   --  type is intended for making changes in buffers at a minimal cost
   --  (e.g avoiding copies of complete buffers when inserting a few
   --  characters), being able to convert from the original buffer's position
   --  information to the line buffer is critical and is achieved using the Len
   --  field.

   type Line_Buffer_Record;
   type Line_Buffer is access Line_Buffer_Record;
   type Line_Buffer_Record is record
      Line : String_Access;
      Len  : Natural;
      Next : Line_Buffer;
   end record;

   procedure Free is new
     Ada.Unchecked_Deallocation (Line_Buffer_Record, Line_Buffer);

   type Extended_Line_Buffer is record
      First   : Line_Buffer;
      Current : Line_Buffer;
   end record;

   function To_Line_Buffer (Buffer : String) return Extended_Line_Buffer;
   --  Convert a string to a line buffer.
   --  CR/LF and LF are treated as end of lines.

   procedure Print (Buffer : Extended_Line_Buffer);
   --  Output the contents of Buffer on standard output.

   procedure Free (Buffer : in out Extended_Line_Buffer);
   --  Free the contents of buffer.

   ----------------------
   -- Parsing Routines --
   ----------------------

   function End_Of_Word (Buffer : String; P : Natural) return Natural;
   --  Return the end of the word pointed by P.

   function Get_Token (S : String) return Token_Type;
   --  Return a token_Type given a string.
   --  For efficiency, S is assumed to start at index 1.

   function Is_Word_Char (C : Character) return Boolean;
   --  Return whether C is a word character (alphanumeric or underscore).
   pragma Inline (Is_Word_Char);

   function Line_Start (Buffer : String; P : Natural) return Natural;
   --  Return the start of the line pointed by P.

   function Line_End   (Buffer : String; P : Natural) return Natural;
   --  Return the end of the line pointed by P.

   function Next_Line  (Buffer : String; P : Natural) return Natural;
   --  Return the start of the next line.

   function Next_Char  (P : Natural) return Natural;
   --  Return the next char in buffer. P is the current character.
   pragma Inline (Next_Char);

   function Prev_Char (P : Natural) return Natural;
   --  Return the previous char in buffer. P is the current character.
   pragma Inline (Prev_Char);

   procedure Replace_Text
     (Buffer  : in out Extended_Line_Buffer;
      First   : Natural;
      Last    : Natural;
      Replace : String);
   --  Replace the slice First .. Last - 1 in Buffer by Replace.

   procedure Do_Indent
     (Buffer      : String;
      New_Buffer  : in out Extended_Line_Buffer;
      Prec        : Natural;
      Indents     : Indent_Stack.Simple_Stack;
      Num_Spaces  : Integer;
      Indent_Done : in out Boolean);
   --  Perform indentation by inserting spaces in the buffer.

   ------------------
   -- Is_Word_Char --
   ------------------

   function Is_Word_Char (C : Character) return Boolean is
   begin
      return C = '_' or else Is_Alphanumeric (C);
   end Is_Word_Char;

   ---------------
   -- Next_Char --
   ---------------

   function Next_Char (P : Natural) return Natural is
   begin
      return P + 1;
   end Next_Char;

   -----------------
   -- End_Of_Word --
   -----------------

   function End_Of_Word (Buffer : String; P : Natural) return Natural is
      Tmp : Natural := P;
   begin
      while Tmp < Buffer'Last
        and then Is_Word_Char (Buffer (Next_Char (Tmp)))
      loop
         Tmp := Next_Char (Tmp);
      end loop;

      return Tmp;
   end End_Of_Word;

   ---------------
   -- Get_Token --
   ---------------

   function Get_Token (S : String) return Token_Type is
   begin
      if S'Length = 1 then
         return Tok_Identifier;
      end if;

      --  Use a case statement instead of a loop for efficiency

      case S (1) is
         when 'a' =>
            case S (2) is
               when 'b' =>
                  if S (3 .. S'Last) = "ort" then
                     return Tok_Abort;
                  elsif S (3 .. S'Last) = "s" then
                     return Tok_Abs;
                  elsif S (3 .. S'Last) = "stract" then
                     return Tok_Abstract;
                  end if;

               when 'c' =>
                  if S (3 .. S'Last) = "cept" then
                     return Tok_Accept;
                  elsif S (3 .. S'Last) = "cess" then
                     return Tok_Access;
                  end if;

               when 'l' =>
                  if S (3 .. S'Last) = "l" then
                     return Tok_All;
                  elsif S (3 .. S'Last) = "iased" then
                     return Tok_Aliased;
                  end if;

               when 'n' =>
                  if S (3 .. S'Last) = "d" then
                     return Tok_And;
                  end if;

               when 'r' =>
                  if S (3 .. S'Last) = "ray" then
                     return Tok_Array;
                  end if;

               when 't' =>
                  if S'Length = 2 then
                     return Tok_At;
                  end if;

               when others =>
                  return Tok_Identifier;
            end case;

         when 'b' =>
            if S (2 .. S'Last) = "egin" then
               return Tok_Begin;
            elsif S (2 .. S'Last) = "ody" then
               return Tok_Body;
            end if;

         when 'c' =>
            if S (2 .. S'Last) = "ase" then
               return Tok_Case;
            elsif S (2 .. S'Last) = "onstant" then
               return Tok_Constant;
            end if;

         when 'd' =>
            if S (2) = 'e' then
               if S (3 .. S'Last) = "clare" then
                  return Tok_Declare;
               elsif S (3 .. S'Last) = "lay" then
                  return Tok_Delay;
               elsif S (3 .. S'Last) = "lta" then
                  return Tok_Delta;
               end if;

            elsif S (2 .. S'Last) = "idgits" then
               return Tok_Digits;
            elsif S (2 .. S'Last) = "o" then
               return Tok_Do;
            end if;

         when 'e' =>
            if S (2 .. S'Last) = "lse" then
               return Tok_Else;
            elsif S (2 .. S'Last) = "lsif" then
               return Tok_Elsif;
            elsif S (2 .. S'Last) = "nd" then
               return Tok_End;
            elsif S (2 .. S'Last) = "ntry" then
               return Tok_Entry;
            elsif S (2 .. S'Last) = "xception" then
               return Tok_Exception;
            elsif S (2 .. S'Last) = "xit" then
               return Tok_Exit;
            end if;

         when 'f' =>
            if S (2 .. S'Last) = "or" then
               return Tok_For;
            elsif S (2 .. S'Last) = "unction" then
               return Tok_Function;
            end if;

         when 'g' =>
            if S (2 .. S'Last) = "eneric" then
               return Tok_Generic;
            elsif S (2 .. S'Last) = "oto" then
               return Tok_Goto;
            end if;

         when 'i' =>
            if S (2 .. S'Last) = "f" then
               return Tok_If;
            elsif S (2 .. S'Last) = "n" then
               return Tok_In;
            elsif S (2 .. S'Last) = "s" then
               return Tok_Is;
            end if;

         when 'l' =>
            if S (2 .. S'Last) = "imited" then
               return Tok_Limited;
            elsif S (2 .. S'Last) = "oop" then
               return Tok_Loop;
            end if;

         when 'm' =>
            if S (2 .. S'Last) = "od" then
               return Tok_Mod;
            end if;

         when 'n' =>
            if S (2 .. S'Last) = "ew" then
               return Tok_New;
            elsif S (2 .. S'Last) = "ot" then
               return Tok_Not;
            elsif S (2 .. S'Last) = "ull" then
               return Tok_Null;
            end if;

         when 'o' =>
            if S (2 .. S'Last) = "thers" then
               return Tok_Others;
            elsif S (2 .. S'Last) = "ut" then
               return Tok_Out;
            elsif S (2 .. S'Last) = "f" then
               return Tok_Of;
            elsif S (2 .. S'Last) = "r" then
               return Tok_Or;
            end if;

         when 'p' =>
            if S (2) = 'r' then
               if S (3 .. S'Last) = "agma" then
                  return Tok_Pragma;
               elsif S (3 .. S'Last) = "ivate" then
                  return Tok_Private;
               elsif S (3 .. S'Last) = "ocedure" then
                  return Tok_Procedure;
               elsif S (3 .. S'Last) = "otected" then
                  return Tok_Protected;
               end if;

            elsif S (2 .. S'Last) = "ackage" then
               return Tok_Package;
            end if;

         when 'r' =>
            if S (2) = 'a' then
               if S (3 .. S'Last) = "ise" then
                  return Tok_Raise;
               elsif S (3 .. S'Last) = "nge" then
                  return Tok_Range;
               end if;

            elsif S (2) = 'e' then
               if S (3 .. S'Last) = "cord" then
                  return Tok_Record;
               elsif S (3 .. S'Last) = "m" then
                  return Tok_Rem;
               elsif S (3 .. S'Last) = "names" then
                  return Tok_Renames;
               elsif S (3 .. S'Last) = "queue" then
                  return Tok_Requeue;
               elsif S (3 .. S'Last) = "turn" then
                  return Tok_Return;
               elsif S (3 .. S'Last) = "verse" then
                  return Tok_Reverse;
               end if;
            end if;

         when 's' =>
            if S (2 .. S'Last) = "elect" then
               return Tok_Select;
            elsif S (2 .. S'Last) = "eparate" then
               return Tok_Separate;
            elsif S (2 .. S'Last) = "ubtype" then
               return Tok_Subtype;
            end if;

         when 't' =>
            if S (2 .. S'Last) = "agged" then
               return Tok_Tagged;
            elsif S (2 .. S'Last) = "ask" then
               return Tok_Task;
            elsif S (2 .. S'Last) = "erminate" then
               return Tok_Terminate;
            elsif S (2 .. S'Last) = "hen" then
               return Tok_Then;
            elsif S (2 .. S'Last) = "ype" then
               return Tok_Type;
            end if;

         when 'u' =>
            if S (2 .. S'Last) = "ntil" then
               return Tok_Until;
            elsif S (2 .. S'Last) = "se" then
               return Tok_Use;
            end if;

         when 'w' =>
            if S (2 .. S'Last) = "hen" then
               return Tok_When;
            elsif S (2 .. S'Last) = "hile" then
               return Tok_While;
            elsif S (2 .. S'Last) = "ith" then
               return Tok_With;
            end if;

         when 'x' =>
            if S (2 .. S'Last) = "or" then
               return Tok_Xor;
            end if;

         when others =>
            return Tok_Identifier;
      end case;

      return Tok_Identifier;
   end Get_Token;

   ----------------
   -- Line_Start --
   ----------------

   function Line_Start (Buffer : String; P : Natural) return Natural is
   begin
      for J in reverse Buffer'First .. P loop
         if Buffer (J) = ASCII.LF or else Buffer (J) = ASCII.CR then
            return J + 1;
         end if;
      end loop;

      return Buffer'First;
   end Line_Start;

   --------------
   -- Line_End --
   --------------

   function Line_End (Buffer : String; P : Natural) return Natural is
   begin
      for J in P .. Buffer'Last loop
         if Buffer (J) = ASCII.LF or else Buffer (J) = ASCII.CR then
            return J - 1;
         end if;
      end loop;

      return Buffer'Last;
   end Line_End;

   ---------------
   -- Next_Line --
   ---------------

   function Next_Line (Buffer : String; P : Natural) return Natural is
   begin
      for J in P .. Buffer'Last - 1 loop
         if Buffer (J) = ASCII.LF then
            return J + 1;
         end if;
      end loop;

      return Buffer'Last;
   end Next_Line;

   ---------------
   -- Prev_Char --
   ---------------

   function Prev_Char (P : Natural) return Natural is
   begin
      return P - 1;
   end Prev_Char;

   ---------------
   -- Do_Indent --
   ---------------

   procedure Do_Indent
     (Buffer      : String;
      New_Buffer  : in out Extended_Line_Buffer;
      Prec        : Natural;
      Indents     : Indent_Stack.Simple_Stack;
      Num_Spaces  : Integer;
      Indent_Done : in out Boolean)
   is
      Start       : Natural;
      Indentation : Integer;
      Index       : Natural;

   begin
      if not Indent_Done then
         Start := Line_Start (Buffer, Prec);
         Index := Start;

         while Buffer (Index) = ' ' or else Buffer (Index) = ASCII.HT loop
            Index := Index + 1;
         end loop;

         if Top (Indents).all = None then
            Indentation := Num_Spaces;
         else
            Indentation := Top (Indents).all;
         end if;

         Replace_Text (New_Buffer, Start, Index, Spaces (1 .. Indentation));
         Indent_Done := True;
      end if;
   end Do_Indent;

   ----------------
   -- Format_Ada --
   ----------------

   procedure Format_Ada
     (Buffer           : String;
      Indent_Level     : Natural     := 3;
      Indent_Continue  : Natural     := 2;
      Reserved_Casing  : Casing_Type := Lower;
      Ident_Casing     : Casing_Type := Mixed;
      Format_Operators : Boolean     := True)
   is
      New_Buffer          : Extended_Line_Buffer;
      Line_Count          : Integer           := 0;
      Str                 : String (1 .. 1024);
      Str_Len             : Natural           := 0;
      Current             : Natural;
      Prec                : Natural           := 1;
      Num_Spaces          : Integer           := 0;
      Indent_Done         : Boolean           := False;
      Num_Parens          : Integer           := 0;
      Prev_Num_Parens     : Integer           := 0;
      In_Generic          : Boolean           := False;
      Type_Decl           : Boolean           := False;
      Was_Type_Decl       : Boolean           := False;
      Subprogram_Decl     : Boolean           := False;
      Syntax_Error        : Boolean           := False;
      Started             : Boolean           := False;
      Token               : Token_Type;
      Prev_Token          : Token_Type := No_Token;
      Tokens              : Token_Stack.Simple_Stack;
      Indents             : Indent_Stack.Simple_Stack;
      Val                 : Token_Stack.Generic_Type_Access;
      Casing              : Casing_Type;
      Default_Extended    : Extended_Token;
      --  Use default values to initialize this variable/constant.

      procedure Handle_Reserved_Word (Reserved : Token_Type);
      --  Handle reserved words.

      procedure Next_Word (P : in out Natural);
      --  Starting at Buffer (P), find the location of the next word
      --  and set P accordingly.
      --  Formatting of operators is performed by this procedure.
      --  The following variables are accessed read-only:
      --    Buffer, Tokens, Num_Spaces, Indent_Continue
      --  The following variables are read and modified:
      --    New_Buffer, Num_Parens, Line_Count, Indents, Indent_Done,
      --    Prev_Token.

      procedure New_Line (Count : in out Natural);
      pragma Inline (New_Line);
      --  Increment Count and poll if needed (e.g for graphic events).

      --------------
      -- New_Line --
      --------------

      procedure New_Line (Count : in out Natural) is
      begin
         Count := Count + 1;
      end New_Line;

      --------------------------
      -- Handle_Reserved_Word --
      --------------------------

      procedure Handle_Reserved_Word (Reserved : Token_Type) is
         Temp : Extended_Token;
      begin
         Temp.Token := Reserved;

         if Reserved = Tok_Body then
            Subprogram_Decl := False;

         elsif Prev_Token /= Tok_End and then Reserved = Tok_If then
            Push (Tokens, Temp);

         elsif Prev_Token /= Tok_End and then Reserved = Tok_Case then
            Do_Indent
              (Buffer, New_Buffer, Prec, Indents, Num_Spaces, Indent_Done);
            Push (Tokens, Temp);
            Num_Spaces := Num_Spaces + Indent_Level;

         elsif Reserved = Tok_Renames then
            Val := Top (Tokens);

            if not Val.Declaration
              and then (Val.Token = Tok_Function
                or else Val.Token = Tok_Procedure
                or else Val.Token = Tok_Package)
            then
               --  Terminate current subprogram declaration, e.g:
               --  procedure ... renames ...;

               Subprogram_Decl := False;
               Pop (Tokens);
            end if;

         elsif not Was_Type_Decl
           and then Prev_Token = Tok_Is
           and then (Reserved = Tok_New
             or else Reserved = Tok_Abstract
             or else Reserved = Tok_Separate)
         then
            --  unindent since this is a declaration, e.g:
            --  package ... is new ...;
            --  function ... is abstract;
            --  function ... is separate;

            Num_Spaces := Num_Spaces - Indent_Level;

            if Num_Spaces < 0 then
               Num_Spaces := 0;
               Syntax_Error := True;
            end if;

            Pop (Tokens);

         elsif Reserved = Tok_Function
           or else Reserved = Tok_Procedure
           or else Reserved = Tok_Package
           or else Reserved = Tok_Task
           or else Reserved = Tok_Protected
           or else Reserved = Tok_Entry
         then
            Type_Decl     := False;
            Was_Type_Decl := False;

            if Reserved /= Tok_Package then
               Subprogram_Decl := True;
               Num_Parens      := 0;
            end if;

            if not In_Generic then
               Val := Top (Tokens);

               if not Val.Declaration
                 and then (Val.Token = Tok_Function
                           or else Val.Token = Tok_Procedure)
               then
                  --  There was a function declaration, e.g:
                  --
                  --  procedure xxx ();
                  --  procedure ...
                  Pop (Tokens);
               end if;

               Push (Tokens, Temp);

            elsif Prev_Token /= Tok_With then
               --  unindent after a generic declaration, e.g:
               --
               --  generic
               --     with procedure xxx;
               --     with function xxx;
               --     with package xxx;
               --  package xxx is

               Num_Spaces := Num_Spaces - Indent_Level;

               if Num_Spaces < 0 then
                  Num_Spaces := 0;
                  Syntax_Error := True;
               end if;

               In_Generic := False;
               Push (Tokens, Temp);
            end if;

         elsif Reserved = Tok_End or else Reserved = Tok_Elsif then
            --  unindent after end of elsif, e.g:
            --
            --  if xxx then
            --     xxx
            --  elsif xxx then
            --     xxx
            --  end if;

            if Reserved = Tok_End then
               case Top (Tokens).Token is
                  when Tok_Exception =>
                     --  Undo additional level of indentation, as in:
                     --     ...
                     --  exception
                     --     when =>
                     --        null;
                     --  end;

                     Num_Spaces := Num_Spaces - Indent_Level;

                     --  End of subprogram
                     Pop (Tokens);

                  when Tok_Case =>
                     Num_Spaces := Num_Spaces - Indent_Level;

                  when others =>
                     null;
               end case;

               Pop (Tokens);
            end if;

            Num_Spaces := Num_Spaces - Indent_Level;

            if Num_Spaces < 0 then
               Num_Spaces   := 0;
               Syntax_Error := True;
            end if;

         elsif     Reserved = Tok_Is
           or else Reserved = Tok_Declare
           or else Reserved = Tok_Begin
           or else Reserved = Tok_Do
           or else (Prev_Token /= Tok_Or  and then Reserved = Tok_Else)
           or else (Prev_Token /= Tok_And and then Reserved = Tok_Then)
           or else (Prev_Token /= Tok_End and then Reserved = Tok_Select)
           or else (Top (Tokens).Token = Tok_Select and then Reserved = Tok_Or)
           or else (Prev_Token /= Tok_End and then Reserved = Tok_Loop)
           or else (Prev_Token /= Tok_End and then Prev_Token /= Tok_Null
                      and then Reserved = Tok_Record)
           or else ((Top (Tokens).Token = Tok_Exception
                       or else Top (Tokens).Token = Tok_Case)
                     and then Reserved = Tok_When)
           or else (Top (Tokens).Declaration
                      and then Reserved = Tok_Private
                      and then Prev_Token /= Tok_Is
                      and then Prev_Token /= Tok_Limited
                      and then Prev_Token /= Tok_With)
         then
            --  unindent for this reserved word, and then indent again, e.g:
            --
            --  procedure xxx is
            --     ...
            --  begin    <--
            --     ...

            if not Type_Decl then
               if Reserved = Tok_Select then
                  --  Start of a select statement
                  Push (Tokens, Temp);
               end if;

               if Reserved = Tok_Else
                 or else (Top (Tokens).Token = Tok_Select
                          and then Reserved = Tok_Then)
                 or else Reserved = Tok_Begin
                 or else Reserved = Tok_Record
                 or else Reserved = Tok_When
                 or else Reserved = Tok_Or
                 or else Reserved = Tok_Private
               then
                  if Reserved = Tok_Begin then
                     Val := Top (Tokens);

                     if Val.Declaration then
                        Num_Spaces := Num_Spaces - Indent_Level;
                        Val.Declaration := False;
                     else
                        Push (Tokens, Temp);
                     end if;

                  elsif Reserved = Tok_Record then
                     Push (Tokens, Temp);
                  else
                     Num_Spaces := Num_Spaces - Indent_Level;
                  end if;

                  if Num_Spaces < 0 then
                     Num_Spaces   := 0;
                     Syntax_Error := True;
                  end if;
               end if;

               Do_Indent
                 (Buffer, New_Buffer, Prec, Indents, Num_Spaces, Indent_Done);
               Num_Spaces := Num_Spaces + Indent_Level;
            end if;

            if Reserved = Tok_Do
              or else Reserved = Tok_Loop
            then
               Push (Tokens, Temp);
            elsif Reserved = Tok_Declare then
               Temp.Declaration := True;
               Push (Tokens, Temp);
            end if;

            if Reserved = Tok_Is then
               if Type_Decl then
                  Was_Type_Decl := True;
                  Type_Decl     := False;
               else
                  Val := Top (Tokens);
                  Subprogram_Decl := False;

                  if Val.Token /= Tok_Case then
                     Val.Declaration := True;
                  end if;
               end if;
            end if;

         elsif Reserved = Tok_Generic then
            --  Indent before a generic entity, e.g:
            --
            --  generic
            --     type ...;

            Do_Indent
              (Buffer, New_Buffer, Prec, Indents, Num_Spaces, Indent_Done);
            Num_Spaces := Num_Spaces + Indent_Level;
            In_Generic := True;

         elsif (Reserved = Tok_Type
                and then Prev_Token /= Tok_Task
                and then Prev_Token /= Tok_Protected)
           or else Reserved = Tok_Subtype
         then
            --  Entering a type declaration/definition.
            --  ??? Should use the stack instead

            Type_Decl := True;

         elsif Reserved = Tok_Exception then
            Val := Top (Tokens);

            if not Val.Declaration then
               Num_Spaces := Num_Spaces - Indent_Level;
               Do_Indent
                 (Buffer, New_Buffer, Prec, Indents, Num_Spaces, Indent_Done);
               Num_Spaces := Num_Spaces + 2 * Indent_Level;
               Push (Tokens, Temp);
            end if;
         end if;

      exception
         when Token_Stack.Stack_Empty =>
            Syntax_Error := True;
      end Handle_Reserved_Word;

      ---------------
      -- Next_Word --
      ---------------

      procedure Next_Word (P : in out Natural) is
         Comma         : String := ", ";
         Spaces        : String := "    ";
         End_Of_Line   : Natural;
         Start_Of_Line : Natural;
         Long          : Natural;
         First         : Natural;
         Last          : Natural;
         Offs          : Natural;
         Insert_Spaces : Boolean;
         Char          : Character;
         Padding       : Integer;

         procedure Handle_Two_Chars (Second_Char : Character);
         --  Handle a two char operator, whose second char is Second_Char.

         procedure Handle_Two_Chars (Second_Char : Character) is
         begin
            Last := P + 2;

            if Buffer (Prev_Char (P)) = ' ' then
               Offs := 2;
               Long := 2;

            else
               Long := 3;
            end if;

            P := Next_Char (P);

            if Buffer (Next_Char (P)) /= ' ' then
               Long := Long + 1;
            end if;

            Spaces (3) := Second_Char;
         end Handle_Two_Chars;

      begin
         if Buffer (P) = ASCII.LF then
            New_Line (Line_Count);
         end if;

         Start_Of_Line := Line_Start (Buffer, P);
         End_Of_Line   := Line_End (Buffer, Start_Of_Line);

         if New_Buffer.Current.Line'First = Start_Of_Line then
            Padding := New_Buffer.Current.Line'Length - New_Buffer.Current.Len;
         else
            Padding := 0;
            Indent_Done := False;
         end if;

         loop
            if P > End_Of_Line then
               Start_Of_Line := Line_Start (Buffer, P);
               End_Of_Line   := Line_End (Buffer, Start_Of_Line);
               New_Line (Line_Count);
               Padding       := 0;
               Indent_Done := False;
            end if;

            --  Skip comments

            while Buffer (P) = '-'
              and then Buffer (Next_Char (P)) = '-'
            loop
               P             := Next_Line (Buffer, P);
               Start_Of_Line := P;
               End_Of_Line   := Line_End (Buffer, P);
               New_Line (Line_Count);
               Padding       := 0;
               Indent_Done := False;
            end loop;

            exit when P = Buffer'Last or else Is_Word_Char (Buffer (P));

            case Buffer (P) is
               when '(' =>
                  Prev_Token := Tok_Left_Paren;
                  Char := Buffer (Prev_Char (P));

                  if Indent_Done then
                     if Format_Operators
                       and then Char /= ' ' and then Char /= '('
                     then
                        Spaces (2) := Buffer (P);
                        Replace_Text (New_Buffer, P, P + 1, Spaces (1 .. 2));
                        Padding := New_Buffer.Current.Line'Length
                          - New_Buffer.Current.Len;
                     end if;

                  else
                     --  Indent with 2 extra spaces if the '(' is the first
                     --  non blank character on the line

                     Do_Indent
                       (Buffer, New_Buffer, P, Indents,
                        Num_Spaces + Indent_Continue, Indent_Done);
                     Padding :=
                       New_Buffer.Current.Line'Length - New_Buffer.Current.Len;
                  end if;

                  Push (Indents, P - Start_Of_Line + Padding + 1);
                  Num_Parens := Num_Parens + 1;

               when ')' =>
                  Prev_Token := Tok_Right_Paren;

                  if Indents = null then
                     --  Syntax error
                     null;
                  else
                     Pop (Indents);
                     Num_Parens := Num_Parens - 1;
                  end if;

               when '"' =>
                  declare
                     First : constant Natural := P;
                     Len   : Natural;
                     Val   : Token_Stack.Generic_Type_Access;

                  begin
                     P := Next_Char (P);

                     while P <= End_Of_Line
                       and then Buffer (P) /= '"'
                     loop
                        P := Next_Char (P);
                     end loop;

                     Val := Top (Tokens);

                     if Val.Token in Token_Class_Declk
                       and then Val.Ident_Len = 0
                     then
                        --  This is an operator symbol, e.g function ">=" (...)

                        Prev_Token := Tok_Operator_Symbol;
                        Len := P - First + 1;
                        Val.Identifier (1 .. Len) := Buffer (First .. P);
                        Val.Ident_Len := Len;

                     else
                        Prev_Token := Tok_String_Literal;
                     end if;
                  end;

               when '&' | '+' | '-' | '*' | '/' | ':' | '<' | '>' | '=' |
                    '|' | '.'
               =>
                  Spaces (2) := Buffer (P);
                  Spaces (3) := ' ';
                  First := P;
                  Last  := P + 1;
                  Offs  := 1;

                  case Buffer (P) is
                     when '+' | '-' =>
                        if Buffer (P) = '+' then
                           Prev_Token := Tok_Minus;
                        else
                           Prev_Token := Tok_Plus;
                        end if;

                        if To_Upper (Buffer (Prev_Char (P))) /= 'E'
                          or else Buffer (Prev_Char (Prev_Char (P)))
                            not in '0' .. '9'
                        then
                           Prev_Token    := Tok_Integer_Literal;
                           Insert_Spaces := True;
                        else
                           Insert_Spaces := False;
                        end if;

                     when '&' | '|' =>
                        if Buffer (P) = '&' then
                           Prev_Token := Tok_Ampersand;
                        else
                           Prev_Token := Tok_Vertical_Bar;
                        end if;

                        Insert_Spaces := True;

                     when '/' | ':' =>
                        Insert_Spaces := True;

                        if Buffer (Next_Char (P)) = '=' then
                           Handle_Two_Chars ('=');

                           if Buffer (P) = '/' then
                              Prev_Token := Tok_Not_Equal;
                           else
                              Prev_Token := Tok_Colon_Equal;
                           end if;

                        elsif Buffer (P) = '/' then
                           Prev_Token := Tok_Slash;
                        else
                           Prev_Token := Tok_Colon;
                        end if;

                     when '*' =>
                        Insert_Spaces := Buffer (Prev_Char (P)) /= '*';

                        if Buffer (Next_Char (P)) = '*' then
                           Handle_Two_Chars ('*');
                           Prev_Token := Tok_Double_Asterisk;
                        else
                           Prev_Token := Tok_Asterisk;
                        end if;

                     when '.' =>
                        Insert_Spaces := Buffer (Next_Char (P)) = '.';

                        if Insert_Spaces then
                           Handle_Two_Chars ('.');
                           Prev_Token := Tok_Dot_Dot;
                        else
                           Prev_Token := Tok_Dot;
                        end if;

                     when '<' =>
                        case Buffer (Next_Char (P)) is
                           when '=' =>
                              Insert_Spaces := True;
                              Prev_Token    := Tok_Less_Equal;
                              Handle_Two_Chars ('=');

                           when '<' =>
                              Prev_Token    := Tok_Less_Less;
                              Insert_Spaces := False;
                              Handle_Two_Chars ('<');

                           when '>' =>
                              Prev_Token    := Tok_Box;
                              Insert_Spaces := False;
                              Handle_Two_Chars ('>');

                           when others =>
                              Prev_Token    := Tok_Less;
                              Insert_Spaces := True;
                        end case;

                     when '>' =>
                        case Buffer (Next_Char (P)) is
                           when '=' =>
                              Insert_Spaces := True;
                              Prev_Token    := Tok_Greater_Equal;
                              Handle_Two_Chars ('=');

                           when '>' =>
                              Prev_Token    := Tok_Greater_Greater;
                              Insert_Spaces := False;
                              Handle_Two_Chars ('>');

                           when others =>
                              Prev_Token    := Tok_Greater;
                              Insert_Spaces := True;
                        end case;

                     when '=' =>
                        Insert_Spaces := True;

                        if Buffer (Next_Char (P)) = '>' then
                           Prev_Token := Tok_Arrow;
                           Handle_Two_Chars ('>');
                        else
                           Prev_Token := Tok_Equal;
                        end if;

                     when others =>
                        null;
                  end case;

                  if Buffer (Prev_Char (P)) = ' ' then
                     First := First - 1;
                  end if;

                  if Spaces (3) = ' ' then
                     if Buffer (Next_Char (P)) = ' '
                       or else Last - 1 = End_Of_Line
                     then
                        Long := 2;
                     else
                        Long := 3;
                     end if;
                  end if;

                  if Format_Operators and then Insert_Spaces and then
                    (Buffer (Prev_Char (P)) /= ' '
                      or else Long /= Last - P + 1)
                  then
                     Replace_Text
                       (New_Buffer, First, Last,
                        Spaces (Offs .. Offs + Long - 1));
                  end if;

               when ',' | ';' =>
                  if Buffer (P) = ';' then
                     Prev_Token := Tok_Semicolon;
                  else
                     Prev_Token := Tok_Comma;
                  end if;

                  Char := Buffer (Next_Char (P));

                  if Format_Operators
                    and then Char /= ' ' and then P /= End_Of_Line
                  then
                     Comma (1) := Buffer (P);
                     Replace_Text (New_Buffer, P, P + 1, Comma (1 .. 2));
                  end if;

               when ''' =>
                  --  Apostrophe. This can either be the start of a character
                  --  literal, an isolated apostrophe used in a qualified
                  --  expression or an attribute. We treat it as a character
                  --  literal if it does not follow a right parenthesis,
                  --  identifier, the keyword ALL or a literal. This means that
                  --  we correctly treat constructs like:
                  --    A := Character'('A');

                  if Prev_Token = Tok_Identifier
                     or else Prev_Token = Tok_Right_Paren
                     or else Prev_Token = Tok_All
                     or else Prev_Token in Token_Class_Literal
                  then
                     Prev_Token := Tok_Apostrophe;
                  else
                     P := Next_Char (Next_Char (P));

                     while P <= End_Of_Line
                       and then Buffer (P) /= '''
                     loop
                        P := Next_Char (P);
                     end loop;

                     Prev_Token := Tok_Char_Literal;
                  end if;

               when others =>
                  null;
            end case;

            P := Next_Char (P);
         end loop;
      end Next_Word;

   begin  --  Format_Ada
      New_Buffer := To_Line_Buffer (Buffer);

      --  Push a dummy token so that stack will never be empty.
      Push (Tokens, Default_Extended);

      --  Push a dummy indentation so that stack will never be empty.
      Push (Indents, None);

      Next_Word (Prec);
      Current := End_Of_Word (Buffer, Prec);

      while Current < Buffer'Last loop
         Str_Len := Current - Prec + 1;

         if Str_Len > 1 or else Buffer (Prec - 1) /= ''' then
            for J in Prec .. Current loop
               Str (J - Prec + 1) := To_Lower (Buffer (J));
            end loop;

            Token := Get_Token (Str (1 .. Str_Len));

            if Subprogram_Decl then
               if Num_Parens = 0 then
                  if Prev_Token = Tok_Semicolon
                    or else Prev_Num_Parens > 0
                  then
                     Subprogram_Decl := False;

                     if Prev_Token = Tok_Semicolon and then not In_Generic then
                        --  subprogram decl with no following reserved word,
                        --  e.g:
                        --  procedure ... ();

                        Pop (Tokens);
                     end if;
                  end if;
               end if;
            end if;

            if Token = Tok_Identifier then
               Val := Top (Tokens);

               if Val.Token in Token_Class_Declk
                 and then Val.Ident_Len = 0
               then
                  --  Store enclosing entity name

                  Val.Identifier (1 .. Str_Len) := Buffer (Prec .. Current);
                  Val.Ident_Len := Str_Len;
               end if;

               Casing := Ident_Casing;

            elsif Prev_Token = Tok_Apostrophe
              and then (Token = Tok_Delta or else Token = Tok_Digits
                        or else Token = Tok_Range or else Token = Tok_Access)
            then
               --  This token should not be considered as a reserved word

               Casing := Ident_Casing;

            else
               Casing := Reserved_Casing;
               Handle_Reserved_Word (Token);
            end if;

            case Casing is
               when Unchanged =>
                  null;

               when Upper =>
                  for J in 1 .. Str_Len loop
                     Str (J) := To_Upper (Str (J));
                  end loop;

                  Replace_Text
                    (New_Buffer, Prec, Current + 1, Str (1 .. Str_Len));

               when Lower =>
                  --  Str already contains lowercase characters.

                  Replace_Text
                    (New_Buffer, Prec, Current + 1, Str (1 .. Str_Len));

               when Mixed =>
                  Mixed_Case (Str (1 .. Str_Len));
                  Replace_Text
                    (New_Buffer, Prec, Current + 1, Str (1 .. Str_Len));
            end case;
         end if;

         if Started then
            Do_Indent
              (Buffer, New_Buffer, Prec, Indents, Num_Spaces, Indent_Done);
         else
            Started := True;
         end if;

         Prev_Num_Parens := Num_Parens;
         Prec            := Current + 1;
         Prev_Token      := Token;
         Next_Word (Prec);

         Syntax_Error :=
           Syntax_Error or else (Prec = Buffer'Last and then Num_Spaces > 0);

         if Syntax_Error then
            Put_Line
              (">>> Syntax Error at line" & Line_Count'Img &
               ", around character" & Current'Img);
         end if;

         Current := End_Of_Word (Buffer, Prec);
      end loop;

      Print (New_Buffer);
      Free (New_Buffer);
   end Format_Ada;

   --------------------
   -- To_Line_Buffer --
   --------------------

   function To_Line_Buffer (Buffer : String) return Extended_Line_Buffer is
      B     : Extended_Line_Buffer;
      Index : Natural := Buffer'First;
      First : Natural;
      Tmp   : Line_Buffer;
      Prev  : Line_Buffer;
      pragma Warnings (Off, Prev);
      --  GNAT will issue a "warning: "Prev" may be null" which cannot occur
      --  since Prev is set to Tmp at the end of each iteration.

   begin
      loop
         exit when Index >= Buffer'Last;

         First := Index;
         Skip_To_Char (Buffer, Index, ASCII.LF);
         Tmp := new Line_Buffer_Record;

         if First = Buffer'First then
            B.First   := Tmp;
            B.Current := B.First;

         else
            Prev.Next := Tmp;
         end if;

         if Index < Buffer'Last and then Buffer (Index + 1) = ASCII.CR then
            Index := Index + 1;
         end if;

         Tmp.Line := new String' (Buffer (First .. Index));
         Tmp.Len  := Tmp.Line'Length;

         Index := Index + 1;
         Prev := Tmp;
      end loop;

      return B;
   end To_Line_Buffer;

   -----------
   -- Print --
   -----------

   procedure Print (Buffer : Extended_Line_Buffer) is
      Tmp  : Line_Buffer := Buffer.First;
   begin
      loop
         exit when Tmp = null;
         Put (Tmp.Line.all);
         Tmp := Tmp.Next;
      end loop;
   end Print;

   ----------
   -- Free --
   ----------

   procedure Free (Buffer : in out Extended_Line_Buffer) is
      Tmp  : Line_Buffer := Buffer.First;
      Prev : Line_Buffer;

   begin
      loop
         exit when Tmp = null;
         Prev := Tmp;
         Tmp := Tmp.Next;
         Free (Prev.Line);
         Free (Prev);
      end loop;
   end Free;

   ------------------
   -- Replace_Text --
   ------------------

   procedure Replace_Text
     (Buffer  : in out Extended_Line_Buffer;
      First   : Natural;
      Last    : Natural;
      Replace : String)
   is
      S          : String_Access;
      F, L       : Natural;
      Line_First : Natural;
      Line_Last  : Natural;
      Padding    : Integer;

   begin
      if Buffer.Current.Line'First + Buffer.Current.Len - 1 < First then
         loop
            Buffer.Current := Buffer.Current.Next;

            exit when Buffer.Current.Line'First + Buffer.Current.Len > First;
         end loop;
      end if;

      Padding := Buffer.Current.Line'Length - Buffer.Current.Len;
      F       := First + Padding;
      L       := Last  + Padding;

      if Last - First = Replace'Length then
         --  Simple case, no need to reallocate buffer

         Buffer.Current.Line (F .. L - 1) := Replace;

      else
         Line_First := Buffer.Current.Line'First;
         Line_Last  := Buffer.Current.Line'Last;

         S := new String
           (Line_First .. Line_Last - ((Last - First) - Replace'Length));
         S (Line_First .. F - 1) := Buffer.Current.Line (Line_First .. F - 1);
         S (F .. F + Replace'Length - 1) := Replace;
         S (F + Replace'Length .. S'Last) :=
           Buffer.Current.Line (L .. Buffer.Current.Line'Last);

         Free (Buffer.Current.Line);
         Buffer.Current.Line := S;
      end if;
   end Replace_Text;

end Source_Analyzer;
