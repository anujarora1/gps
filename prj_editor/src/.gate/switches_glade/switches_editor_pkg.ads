with Gtk.Window; use Gtk.Window;
with Gtk.Box; use Gtk.Box;
with Gtk.Notebook; use Gtk.Notebook;
with Gtk.Table; use Gtk.Table;
with Gtk.Frame; use Gtk.Frame;
with Gtk.Check_Button; use Gtk.Check_Button;
with Gtk.Adjustment; use Gtk.Adjustment;
with Gtk.Spin_Button; use Gtk.Spin_Button;
with Gtk.GEntry; use Gtk.GEntry;
with Gtk.Label; use Gtk.Label;
with Gtk.Combo; use Gtk.Combo;
with Gtk.GEntry; use Gtk.GEntry;
with Gtk.Radio_Button; use Gtk.Radio_Button;
with Gtk.Hbutton_Box; use Gtk.Hbutton_Box;
with Gtk.Button; use Gtk.Button;
package Switches_Editor_Pkg is

   type Switches_Editor_Record is new Gtk_Window_Record with record
      Vbox2 : Gtk_Vbox;
      Notebook1 : Gtk_Notebook;
      Make_Switches : Gtk_Table;
      Frame26 : Gtk_Frame;
      Vbox25 : Gtk_Vbox;
      Make_All_Files : Gtk_Check_Button;
      Make_Recompile_Switches : Gtk_Check_Button;
      Make_Minimal_Recompile : Gtk_Check_Button;
      Frame27 : Gtk_Frame;
      Vbox26 : Gtk_Vbox;
      Hbox1 : Gtk_Hbox;
      Make_Multiprocessing : Gtk_Check_Button;
      Num_Processes : Gtk_Spin_Button;
      Make_Keep_Going : Gtk_Check_Button;
      Make_Debug : Gtk_Check_Button;
      Make_Switches_Entry : Gtk_Entry;
      Label17 : Gtk_Label;
      Compiler_Switches : Gtk_Table;
      Frame21 : Gtk_Frame;
      Vbox19 : Gtk_Vbox;
      Optimization_Level : Gtk_Combo;
      Optimization_Level_Entry : Gtk_Entry;
      Compile_No_Inline : Gtk_Check_Button;
      Compile_Interunit_Inlining : Gtk_Check_Button;
      Compile_Unroll_Loops : Gtk_Check_Button;
      Frame22 : Gtk_Frame;
      Vbox20 : Gtk_Vbox;
      Compile_Overflow_Checking : Gtk_Check_Button;
      Compile_Suppress_All_Checks : Gtk_Check_Button;
      Compile_Stack_Checking : Gtk_Check_Button;
      Compile_Dynamic_Elaboration : Gtk_Check_Button;
      Frame23 : Gtk_Frame;
      Vbox21 : Gtk_Vbox;
      Compile_Full_Errors : Gtk_Check_Button;
      Compile_No_Warnings : Gtk_Check_Button;
      Compile_Warning_Error : Gtk_Check_Button;
      Compile_Elab_Warning : Gtk_Check_Button;
      Compile_Unused_Warning : Gtk_Check_Button;
      Compile_Style_Checks : Gtk_Check_Button;
      Vbox22 : Gtk_Vbox;
      Frame24 : Gtk_Frame;
      Vbox23 : Gtk_Vbox;
      Compile_Assertions : Gtk_Check_Button;
      Compile_Debug_Expanded_Code : Gtk_Check_Button;
      Hbox2 : Gtk_Hbox;
      Label22 : Gtk_Label;
      Compile_Representation_Info : Gtk_Combo;
      Combo_Entry1 : Gtk_Entry;
      Frame25 : Gtk_Frame;
      Vbox24 : Gtk_Vbox;
      Compile_Language_Extensions : Gtk_Check_Button;
      Compile_Ada83_Mode : Gtk_Check_Button;
      Compiler_Switches_Entry : Gtk_Entry;
      Label18 : Gtk_Label;
      Binder_Switches : Gtk_Table;
      Binder_Switches_Entry : Gtk_Entry;
      Vbox27 : Gtk_Vbox;
      Binder_Tracebacks : Gtk_Check_Button;
      Binder_Static_Gnat : Gtk_Radio_Button;
      Binder_Shared_Gnat : Gtk_Radio_Button;
      Label19 : Gtk_Label;
      Linker_Switches : Gtk_Table;
      Linker_Switches_Entry : Gtk_Entry;
      Vbox40 : Gtk_Vbox;
      Linker_Strip : Gtk_Check_Button;
      Label20 : Gtk_Label;
      Hbuttonbox1 : Gtk_Hbutton_Box;
   end record;
   type Switches_Editor_Access is access all Switches_Editor_Record'Class;

   procedure Gtk_New (Switches_Editor : out Switches_Editor_Access);
   procedure Initialize (Switches_Editor : access Switches_Editor_Record'Class);

end Switches_Editor_Pkg;
