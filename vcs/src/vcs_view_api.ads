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

with Glib.Object;   use Glib.Object;
with Glide_Kernel;  use Glide_Kernel;
with Gtk.Menu;      use Gtk.Menu;

package VCS_View_API is

   procedure Open
     (Widget  : access GObject_Record'Class;
      Kernel  : Kernel_Handle);

   procedure Update
     (Widget  : access GObject_Record'Class;
      Kernel  : Kernel_Handle);

   procedure View_Diff
     (Widget  : access GObject_Record'Class;
      Kernel  : Kernel_Handle);

   procedure View_Log
     (Widget  : access GObject_Record'Class;
      Kernel  : Kernel_Handle);

   procedure View_Annotate
     (Widget  : access GObject_Record'Class;
      Kernel  : Kernel_Handle);

   procedure Edit_Log
     (Widget  : access GObject_Record'Class;
      Kernel  : Kernel_Handle);

   procedure Commit
     (Widget  : access GObject_Record'Class;
      Kernel  : Kernel_Handle);

   procedure Add
     (Widget  : access GObject_Record'Class;
      Kernel  : Kernel_Handle);

   procedure Remove
     (Widget  : access GObject_Record'Class;
      Kernel  : Kernel_Handle);

   procedure Revert
     (Widget  : access GObject_Record'Class;
      Kernel  : Kernel_Handle);

   procedure VCS_Contextual_Menu
     (Object  : access Glib.Object.GObject_Record'Class;
      Context : access Selection_Context'Class;
      Menu    : access Gtk.Menu.Gtk_Menu_Record'Class);

end VCS_View_API;
