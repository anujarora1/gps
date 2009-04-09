-----------------------------------------------------------------------
--                               G P S                               --
--                                                                   --
--                   Copyright (C) 2001-2009, AdaCore                --
--                                                                   --
-- GPS is free  software;  you can redistribute it and/or modify  it --
-- under the terms of the GNU General Public License as published by --
-- the Free Software Foundation; either version 2 of the License, or --
-- (at your option) any later version.                               --
--                                                                   --
-- This program is  distributed in the hope that it will be  useful, --
-- but  WITHOUT ANY WARRANTY;  without even the  implied warranty of --
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU --
-- General Public License for more details. You should have received --
-- a copy of the GNU General Public License along with this program; --
-- if not,  write to the  Free Software Foundation, Inc.,  59 Temple --
-- Place - Suite 330, Boston, MA 02111-1307, USA.                    --
-----------------------------------------------------------------------

with Ada.Characters.Handling;   use Ada.Characters.Handling;
with Ada.Strings.Fixed;         use Ada.Strings.Fixed;
--  with GNAT.OS_Lib;               use GNAT.OS_Lib;
with GNATCOLL.VFS_Utils;        use GNATCOLL.VFS_Utils;

package body File_Utils is

   ------------------
   -- To_File_Name --
   ------------------

   function To_File_Name (Name : Filesystem_String) return Filesystem_String is
      Result : String (1 .. Name'Length) := To_Lower (+Name);
   begin
      for J in Result'First .. Result'Last loop
         if Result (J) = '.' then
            Result (J) := '-';
         end if;
      end loop;

      return +Result;
   end To_File_Name;

--     ----------------------
--     -- To_Host_Pathname --
--     ----------------------
--
--     function To_Host_Pathname
--       (Path : Filesystem_String) return Filesystem_String is
--        Cygdrv : constant Filesystem_String := "cygdrive";
--     begin
--        if GNAT.OS_Lib.Directory_Separator = '/' then
--           return Path;
--        end if;
--
--        --  Replace /cygdrive/x/ by x:\
--
--        if Path'Length > Cygdrv'Length + 3
--          and then Is_Directory_Separator (Path (Path'First))
--          and then
--          Equal (Path (Path'First + 1 .. Path'First + Cygdrv'Length), Cygdrv)
--      and then Is_Directory_Separator (Path (Path'First + Cygdrv'Length + 1))
--      and then Is_Directory_Separator (Path (Path'First + Cygdrv'Length + 3))
--        then
--           return
--              Path (Path'First + Cygdrv'Length + 2) & (+":\") &
--              Path (Path'First + Cygdrv'Length + 4 .. Path'Last);
--        else
--           return Path;
--        end if;
--     end To_Host_Pathname;

--     ----------------------
--     -- To_Unix_Pathname --
--     ----------------------
--
--     function To_Unix_Pathname
--       (Path : Filesystem_String) return Filesystem_String is
--        Result : Filesystem_String (Path'Range);
--     begin
--        if GNAT.OS_Lib.Directory_Separator = '/' then
--           return Path;
--        end if;
--
--        for J in Result'Range loop
--           if Path (J) = GNAT.OS_Lib.Directory_Separator then
--              Result (J) := '/';
--           else
--              Result (J) := Path (J);
--           end if;
--        end loop;
--
--        return Result;
--     end To_Unix_Pathname;

   -------------
   -- Shorten --
   -------------

   function Shorten
     (Path    : String;
      Max_Len : Natural := 40) return String
   is
      Len : constant Natural := Path'Length;
   begin
      if Len <= Max_Len then
         return Path;
      else
         declare
            Prefix       : constant String  := "[...]";
            Search_Start : constant Natural
              := Path'Last - Max_Len + Prefix'Length;
            New_Start    : Natural;
         begin
            if Search_Start > Path'Last then
               --  Max_Len < Prefix'Length
               --  Shorten anyway, but might give a strange result
               return Path (Path'Last - Max_Len .. Path'Last);
            end if;

            New_Start := Index (Path (Search_Start .. Path'Last), "/");

            if New_Start = 0 and New_Start not in Path'Range then
               --  Shorten anyway (but it might not make sense)
               New_Start := Search_Start;
            end if;

            return (Prefix & Path (New_Start .. Path'Last));
         end;
      end if;
   end Shorten;

   --------------------
   -- Suffix_Matches --
   --------------------

   function Suffix_Matches
     (File_Name : Filesystem_String; Suffix : Filesystem_String) return Boolean
   is
      pragma Suppress (All_Checks);
   begin
      --  This version is slightly faster than checking
      --     return Tail (File_Name, Suffix'Length) = Suffix;
      --  which needs a function returning a string.

      if File_Name'Length < Suffix'Length then
         return False;
      end if;

      --  Do the loop in reverse, since it likely that Suffix starts with '.'
      --  In the GPS case, it is also often the case that suffix starts with
      --  '.ad' for Ada extensions
      for J in reverse Suffix'Range loop
         if File_Name (File_Name'Last + J - Suffix'Last) /= Suffix (J) then
            return False;
         end if;
      end loop;

      return True;
   end Suffix_Matches;

   -----------------------------
   -- Is_Absolute_Path_Or_URL --
   -----------------------------

   function Is_Absolute_Path_Or_URL
     (Name : Filesystem_String) return Boolean
   is
      Index : Natural;
   begin
      if Is_Absolute_Path (Name) then
         return True;
      end if;

      Index := Name'First;
      while Index <= Name'Last - 3
        and then Name (Index) /= ':'
      loop
         Index := Index + 1;
      end loop;

      return Index <= Name'Last - 3
        and then Equal (Name (Index .. Index + 2), "://");
   end Is_Absolute_Path_Or_URL;

end File_Utils;
