------------------------------------------------------------------------------
--                                  G P S                                   --
--                                                                          --
--                     Copyright (C) 2000-2013, AdaCore                     --
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

with Gdk;                  use Gdk;
with Gdk.Event;            use Gdk.Event;
with Gdk.Rectangle;        use Gdk.Rectangle;
with Gdk.Screen;           use Gdk.Screen;
with Gdk.Types;
with Gdk.Window;           use Gdk.Window;
with Glib.Main;            use Glib.Main;
with Glib.Object;          use Glib.Object;
with Glib.Properties;      use Glib.Properties;
with GNATCOLL.Traces;      use GNATCOLL.Traces;
with Gtkada.Handlers;      use Gtkada.Handlers;
with Gtk.Enums;            use Gtk.Enums;
with Gtk.Main;
with Gtk.Settings;         use Gtk.Settings;
with Gtk.Style_Context;    use Gtk.Style_Context;
with Gtk.Tree_Model;       use Gtk.Tree_Model;
with Gtk.Tree_View;        use Gtk.Tree_View;
with Gtk.Tree_View_Column; use Gtk.Tree_View_Column;
with Gtk.Window;           use Gtk.Window;

package body Tooltips is
   Me : constant Trace_Handle := Create ("TOOLTIPS");

   procedure Destroy_Cb (Data : Tooltips_Access);
   --  Called when the tooltip is being destroyed

   function On_Tooltip_Delay return Boolean;
   --  Called when the mouse has been motionless for a while

   procedure Hide_Tooltip;
   procedure Show_Tooltip
     (Widget  : not null access Gtk_Widget_Record'Class;
      Tooltip : access Tooltips'Class);
   --  Hide or show the tooltip

   function Is_In_Area (X, Y : Gint) return Boolean;
   --  Return True if the global tooltip is present, mapped, and the pointer
   --  location given by X,Y is within the area.

   function Tooltip_Event_Cb
     (Widget  : access Gtk.Widget.Gtk_Widget_Record'Class;
      Event   : Gdk.Event.Gdk_Event) return Boolean;
   --  Callback for all events that will disable the tooltip
   --  e.g: focus_in/focus_out/motion_notify/button_clicked/key_press

   package Tooltip_User_Data is new Glib.Object.User_Data (Tooltips_Access);

   type Tooltip_Object_Record is new Gtk.Window.Gtk_Window_Record with record
      Timeout    : Gint;

      Timeout_Id : G_Source_Id := 0;
      On_Widget : Gtk_Widget;
      Tip       : Tooltips_Access;  --  function to compute its contents

      X, Y      : Glib.Gint;

      Area_Is_Set : Boolean := False;
      Area        : Gdk.Rectangle.Gdk_Rectangle := (0, 0, 0, 0);
   end record;
   type Tooltip_Object is access all Tooltip_Object_Record'Class;
   --  There is one such object in the application.
   --  gtk+ creates one per display.

   Global_Tooltip : Tooltip_Object;

   -------------------------------
   -- Tooltips_Foreground_Color --
   -------------------------------

   function Tooltips_Foreground_Color return Gdk.RGBA.Gdk_RGBA is
      Color : Gdk_RGBA;
   begin
      Get_Style_Context (Global_Tooltip).Get_Color
        (Gtk_State_Flag_Normal, Color);
      return Color;
   end Tooltips_Foreground_Color;

   ------------------
   -- Set_Tip_Area --
   ------------------

   procedure Set_Tip_Area
     (Tooltip : not null access Tooltips;
      Area    : Gdk.Rectangle.Gdk_Rectangle)
   is
   begin
      if Global_Tooltip /= null
        and then Global_Tooltip.Tip = Tooltips_Access (Tooltip)
      then
         Global_Tooltip.Area_Is_Set := True;
         Global_Tooltip.Area := Area;
         Trace (Me, "Set_Tip_Area"
                & Area.X'Img & Area.Y'Img & Area.Width'Img & Area.Height'Img);
      end if;
   end Set_Tip_Area;

   ----------------------
   -- On_Tooltip_Delay --
   ----------------------

   function On_Tooltip_Delay return Boolean is
      Widget : Gtk_Widget;
      Win_Width, Win_Height : Gint;
      X, Y, W, H : Gint;
   begin
      if Global_Tooltip /= null then
         Global_Tooltip.Timeout_Id := 0;
      end if;

      Widget := Global_Tooltip.Tip.Create_Contents
        (Global_Tooltip.On_Widget,
         Global_Tooltip.X,
         Global_Tooltip.Y);

      if Widget /= null then
         Global_Tooltip.Add (Widget);

         Win_Width := Get_Width (Gdk.Screen.Get_Default);
         Win_Height := Get_Height (Gdk.Screen.Get_Default);

         Gdk.Window.Get_Root_Coords
           (Global_Tooltip.On_Widget.Get_Window,
            Global_Tooltip.X, Global_Tooltip.Y,
            X, Y);

         Global_Tooltip.Realize;
         W := Global_Tooltip.Get_Allocated_Width;
         H := Global_Tooltip.Get_Allocated_Height;

         if X + W > Win_Width then
            X := Win_Width - W - 12;
         end if;

         if Y + H > Win_Height then
            Y := Win_Height - H - 12;
         end if;

         Global_Tooltip.Move (X + 10, Y + 10);
         Global_Tooltip.Show_All;
      else
         Trace (Me, "No tooltip to display at this location");
      end if;

      return False;

   exception
      when E : others =>
         Trace (Me, E);
         return False;
   end On_Tooltip_Delay;

   ----------------
   -- Is_In_Area --
   ----------------

   function Is_In_Area (X, Y : Gint) return Boolean is
   begin
      return Global_Tooltip.Get_Mapped
        and then Global_Tooltip.Area_Is_Set
        and then not
          (X < Global_Tooltip.Area.X
           or else X > Global_Tooltip.Area.X + Global_Tooltip.Area.Width
           or else Y < Global_Tooltip.Area.Y
           or else Y > Global_Tooltip.Area.Y + Global_Tooltip.Area.Height);
   end Is_In_Area;

   ------------------
   -- Show_Tooltip --
   ------------------

   procedure Show_Tooltip
     (Widget  : not null access Gtk_Widget_Record'Class;
      Tooltip : access Tooltips'Class)
   is
      X, Y            : Gint;
      Settings        : Gtk_Settings;
      Window, Ignored : Gdk_Window;
      Mask            : Gdk.Types.Gdk_Modifier_Type;
   begin
      if Global_Tooltip = null then
         Global_Tooltip := new Tooltip_Object_Record;
         Gtk.Window.Initialize (Global_Tooltip, Window_Popup);

         Global_Tooltip.Set_Border_Width (10);
         Global_Tooltip.Set_Type_Hint (Window_Type_Hint_Tooltip);
         Global_Tooltip.Set_Resizable (False);
         Global_Tooltip.Set_Name ("gtk-tooltip");
         Get_Style_Context (Global_Tooltip).Add_Class ("tooltip");

         Settings := Gtk.Settings.Get_Default;
         Global_Tooltip.Timeout := Int_Properties.Get_Property
           (Settings, Int_Properties.Property (Gtk_Tooltip_Timeout_Property));
         Trace (Me, "Timeout for tooltips is"
                & Global_Tooltip.Timeout'Img);
      end if;

      Window := Widget.Get_Window;

      Gdk.Window.Get_Device_Position
        (Self   => Window,
         Device => Gtk.Main.Get_Current_Event_Device,
         X      => X,
         Y      => Y,
         Mask   => Mask,
         Window => Ignored);

      --  If still within the current area

      if Is_In_Area (X, Y) then
         --  Leave the tooltip as is
         return;
      end if;

      Hide_Tooltip;

      Global_Tooltip.On_Widget := Gtk_Widget (Widget);
      Global_Tooltip.Tip := Tooltips_Access (Tooltip);
      Global_Tooltip.X := X;
      Global_Tooltip.Y := Y;
      Global_Tooltip.Timeout_Id := Glib.Main.Timeout_Add
        (Guint (Global_Tooltip.Timeout), On_Tooltip_Delay'Access);
   end Show_Tooltip;

   ------------------
   -- Hide_Tooltip --
   ------------------

   procedure Hide_Tooltip is
      Child : Gtk_Widget;
   begin
      if Global_Tooltip /= null then
         if Global_Tooltip.Timeout_Id /= 0 then
            Glib.Main.Remove (Global_Tooltip.Timeout_Id);
            Global_Tooltip.Timeout_Id := 0;
         end if;

         Global_Tooltip.On_Widget := null;
         Global_Tooltip.Area_Is_Set := False;
         Global_Tooltip.Hide;

         Child := Global_Tooltip.Get_Child;
         if Child /= null then
            Global_Tooltip.Remove (Child);
         end if;
      end if;
   end Hide_Tooltip;

   ----------------------
   -- Tooltip_Event_Cb --
   ----------------------

   function Tooltip_Event_Cb
     (Widget  : access Gtk.Widget.Gtk_Widget_Record'Class;
      Event   : Gdk.Event.Gdk_Event) return Boolean
   is
      Tip : Tooltips_Access;
   begin
      if Get_Event_Type (Event) = Motion_Notify
        and then Get_Property
          (Gtk_Window (Widget.Get_Toplevel), Has_Toplevel_Focus_Property)
      then
         Tip := Tooltip_User_Data.Get (Widget, "gps-tooltip");
         Show_Tooltip (Widget, Tip);
      else
         Hide_Tooltip;
      end if;

      return False;
   end Tooltip_Event_Cb;

   -----------------
   -- Set_Tooltip --
   -----------------

   procedure Set_Tooltip
     (Tooltip   : access Tooltips'Class;
      On_Widget : access Gtk.Widget.Gtk_Widget_Record'Class) is
   begin
      Add_Events
        (On_Widget,
         Pointer_Motion_Mask or Enter_Notify_Mask or Focus_Change_Mask
         or Leave_Notify_Mask);
      Return_Callback.Connect
        (On_Widget, Signal_Button_Press_Event,
         Return_Callback.To_Marshaller (Tooltip_Event_Cb'Access));
      Return_Callback.Connect
        (On_Widget, Signal_Key_Press_Event,
         Return_Callback.To_Marshaller (Tooltip_Event_Cb'Access));
--        Return_Callback.Connect
--          (On_Widget, Signal_Key_Release_Event,
--           Return_Callback.To_Marshaller (Tooltip_Event_Cb'Access));
      Return_Callback.Connect
        (On_Widget, Signal_Motion_Notify_Event,
         Return_Callback.To_Marshaller (Tooltip_Event_Cb'Access));
      Return_Callback.Connect
        (On_Widget, Signal_Leave_Notify_Event,
         Return_Callback.To_Marshaller (Tooltip_Event_Cb'Access));
      Return_Callback.Connect
        (On_Widget, Signal_Scroll_Event,
         Return_Callback.To_Marshaller (Tooltip_Event_Cb'Access));
      Return_Callback.Connect
        (On_Widget, Signal_Focus_In_Event,
         Return_Callback.To_Marshaller (Tooltip_Event_Cb'Access));
      Return_Callback.Connect
        (On_Widget, Signal_Focus_Out_Event,
         Return_Callback.To_Marshaller (Tooltip_Event_Cb'Access));

      Tooltip_User_Data.Set
        (On_Widget, Tooltips_Access (Tooltip),
         "gps-tooltip", Destroy_Cb'Access);
   end Set_Tooltip;

   ----------------
   -- Destroy_Cb --
   ----------------

   procedure Destroy_Cb (Data : Tooltips_Access) is
   begin
      Trace (Me, "Destroying a tooltip");
      Destroy (Data);
   end Destroy_Cb;

   -------------------------
   -- Initialize_Tooltips --
   -------------------------

   procedure Initialize_Tooltips
     (Tree : access Gtk.Tree_View.Gtk_Tree_View_Record'Class;
      X, Y : Gint;
      Area : out Gdk.Rectangle.Gdk_Rectangle;
      Iter : out Gtk.Tree_Model.Gtk_Tree_Iter)
   is
      Cell_X, Cell_Y : Gint;
      Path           : Gtk_Tree_Path;
      Found          :  Boolean;
      Column         : Gtk_Tree_View_Column;
   begin
      Area := (0, 0, 0, 0);
      Iter := Null_Iter;

      Get_Path_At_Pos (Tree, X, Y, Path, Column, Cell_X, Cell_Y, Found);
      if not Found then
         return;
      end if;

      Get_Cell_Area (Tree, Path, Column, Area);
      Iter := Get_Iter (Get_Model (Tree), Path);
      Path_Free (Path);
   end Initialize_Tooltips;

end Tooltips;