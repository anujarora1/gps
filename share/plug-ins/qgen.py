"""
This plugin adds support for QGen and generates Ada and C code from Simulink
models.

To use this plugin, you must install qgen, and have "qgenc" available
in your PATH.

Your project must also add the "Simulink" language to its Languages attribute.
At this point, opening an .mdl file will show a diagram instead of showing the
text of the .mdl file.  Double-click on a system block to open it and see other
diagrams.

The project can optionally include an output directory for the
generated code. This directory defaults to the project's object_dir.

    project Default is
       for Languages use ("Ada", "C");
       for Source_Dirs use (".", "generated");
       package QGen is
          for Output_Dir use "generated";
       end QGen;
    end Default;

The project can also be used to override the types file used when
generating code. The default is to use a file with the same name
as the .mdl, but with extension _types.txt. If some other file is
needed, you can use:

    package QGen is
       for Switches ("myfile.mdl") use ("-t", "mytypes.txt");
    end QGen;

A contextual menu is provided when you right-click on an .mdl file,
to generate code from that file. This menu is available in particular
in the project view and in the diagrams themselves.
Convenient toolbar buttons are enabled to generate-then-build or even
generate-then-build-then-debug.
Whenever qgen has finished running, GPS will automatically reload the
project to make the newly generated files available.
"""

import json
import GPS
import GPS.Browsers
import glob
import gps_utils
import gpsbrowsers
import modules
import os
import os.path
import os_utils
import re
import workflows
from workflows.promises import Promise, ProcessWrapper, TargetWrapper


logger = GPS.Logger('MODELING')


class Project_Support(object):
    """
    This class provides an interface to the project facilities, to be
    used by QGen.
    """

    def register_languages(self):
        """Add support for the Simulink language"""
        GPS.parse_xml("""<?xml version='1.0' ?>
          <GPS>
            <Language>
              <Name>Simulink</Name>
              <Body_Suffix>.mdl</Body_Suffix>
              <Obj_Suffix>-</Obj_Suffix>
            </Language>
            <Language>
              <Name>Simulink_Json</Name>
              <Body_Suffix>.mdl.json</Body_Suffix>
              <Obj_Suffix>-</Obj_Suffix>
            </Language>
          </GPS>""")

    def register_tool(self):
        """Register the QGENC tool and its switches"""

        GPS.parse_xml("""<?xml version='1.0' ?>
           <GPS>
             <project_attribute
              package="QGen"
              name="Output_Dir"
              editor_page="QGen"
              label="Output directory"
              description="The location of all generated source code files"
              hide_in="wizard library_wizard">
                <string type="directory"/>
             </project_attribute>

             <project_attribute
              package="QGen"
              name="Switches"
              editor_page="QGen"
              list="true"
              label="Switches"
              hide_in="wizard library_wizard">
                <index attribute='Languages'>
                   <string />
                </index>
             </project_attribute>

             <target-model name="QGenc" category="">
               <description>Generic launch of QGen</description>
               <iconname>gps-build-all-symbolic</iconname>
               <switches>
               </switches>
             </target-model>

             <target model="QGenc" category="_File_" name="QGen for file">
               <in-toolbar>FALSE</in-toolbar>
               <in-menu>FALSE</in-menu>
               <launch-mode>MANUALLY_WITH_NO_DIALOG</launch-mode>
               <read-only>TRUE</read-only>
               <command-line>
                 <arg>qgenc</arg>
                 <arg>--trace</arg>
                 <arg>-i</arg>
                 <arg>-l</arg>
                 <arg>ada</arg>
               </command-line>
             </target>

             <tool
              name="QGENC"
              package="QGen"
              index="Simulink">
               <language>Simulink</language>
               <switches>
                 <title line="1">Files</title>
                 <title line="2">Generation</title>
                 <title line="3">Output</title>

                 <field
                  line="1"
                  label="Matlab file"
                  switch="-m"
                  separator=" "
                  as-file="true"
                 tip="Provides variable declarations of the Matlab workspace"/>
                 <field
                  line="1"
                  label="Typing file"
                  switch="-t"
                  separator=" "
                  as-file="true"
                  tip="Provides Simulink block typing information"/>
                 <field
                  line="1"
                  label="Library directory"
                  switch="-b"
                  separator=" "
                  as-directory="true"
                  tip=""/>

                 <combo
                  line="2"
                  label="Target language"
                  switch="-l"
                  separator=" "
             tip="The language used by QGENC to produce the generated files">
                    <combo-entry label="Ada" value="ada"/>
                    <combo-entry label="C" value="c"/>
                 </combo>
                 <check
                  line="2"
                  label="Flatten model"
                  switch="--full-flattening"
                  tip=""/>

                 <radio line="3">
                   <radio-entry
                    label="Delete"
                    switch="-c"
             tip="Delete contents of output directory between compilations"/>
                   <radio-entry
                    label="Preserve"
                    switch="-i"
             tip="Preserve contents of output directory between compilations"/>
                 </radio>
               </switches>
             </tool>
           </GPS>""")

    def get_output_dir(self, file):
        """
        Return the output directory to use when generating code for file.
        It default to the project's object directory.

        :param GPS.File file: the .mdl file
        """
        p = file.project()
        dir = p.get_attribute_as_string(
            package='QGen', attribute='Output_Dir')
        if dir:
            # Get absolute directory from Output_Dir
            dir = os.path.join(os.path.dirname(p.file().name()), dir)
        else:
            try:
                return p.object_dirs()[0]
            except:
                return GPS.Project.root().object_dirs()[0]
        return dir

    def get_switches(self, file):
        """
        Return the wswitches to use for a specific file
        :param GPS.File file: the .mdl file
        :return str: the list of switches
        """
        try:
            switches = file.project().get_attribute_as_string(
                attribute='Switches', package='QGen',
                index=os.path.basename(file.name()))
            if not switches:
                switches = file.project().get_attribute_as_string(
                    attribute='Switches', package='QGen',
                    index='simulink')
        except:
            switches = ''

        return switches


class CLI(GPS.Process):
    """
    An interface to the mdl2json executable. This is responsible for
    converting an mdl file to a JSON format that can be displayed by GPS.
    """

    qgenc = os_utils.locate_exec_on_path('qgenc')
    # path to qgenc

    mdl2json = os.path.normpath(
        os.path.join(
            os.path.dirname(qgenc),
            '..', 'libexec', 'qgen', 'bin', 'mdl2json'))
    # path to mdl2json

    @staticmethod
    def is_available():
        """
        Whether mdl2json is available on the system.
        """
        # Testing None or empty string
        if CLI.qgenc:
            return True
        else:
            return False

    @staticmethod
    def get_json(file):
        """
        Compute the JSON to display the given .mdl file
        :param GPS.File file: the .mdl file to analyze
        :return: a promise, that passes the full output of the process
           when resolved
        """

        promise = Promise()

        # Get switches, but remove the ones that do not apply to mdl2json
        switches = re.sub(
            "--full-flattening", "", project_support.get_switches(file))
        outdir = project_support.get_output_dir(file)

        cmd = ' '.join([CLI.mdl2json, file.name(), switches])

        def __on_exit(proc, exit_status, output):
            if exit_status == 0:
                promise.resolve(output)
            else:
                GPS.Console().write('When running mdl2json: %s\n' % (
                    output), mode='error')
                promise.reject()

        # mdl2json is relatively fast, and since the user is waiting for
        # its output to see the diagram, we run in active mode below.
        GPS.Process(command=cmd, on_exit=__on_exit, active=True)
        return promise

    ###########
    # Compiling models
    ###########

    @staticmethod
    def is_model_file(ctx_or_file):
        """
        Whether the current context is a model file.
        :param ctx: either a `GPS.Context` or a `GPS.File`
        """
        try:
            if isinstance(ctx_or_file, GPS.Context):
                f = ctx_or_file.file()
            else:
                f = ctx_or_file
            return f.language() == 'simulink'
        except:
            return False

    @staticmethod
    def is_model_block_and_debugger(ctx):
        """
        Whether the current context is a model block.
        """
        try:
            debug = GPS.Debugger.get()
            return (
                debug is not None and                  # in a debugger
                hasattr(ctx, "modeling_item") and  # see on_create_context
                CLI.is_model_file(ctx))
        except:
            return False

    @staticmethod
    def __compile_files_to_source_code(files):
        """
        A python generator that generates code for the `mdl` source file.
        :param files: A list of `GPS.File`, from which to generate code.
        :return: the last yield is the status (0 if everything succeeded)
        """
        # Compute the extra switches. The user can override -t, for instance,
        # by setting the project attribute Switches("file.mdl") with a
        # proper version of -t.

        st = 1
        for f in files:
            if CLI.is_model_file(f):
                base = os.path.splitext(os.path.basename(f.name()))[0]
                switches = [
                    "-o", project_support.get_output_dir(f),
                    "-t", "%s_types.txt" % base]
                switches = (' '.join(switches) +
                            ' ' + project_support.get_switches(f) +
                            ' ' + f.name())
                w = TargetWrapper(target_name='QGen for file')
                st = yield w.wait_on_execute(file=f, extra_args=switches)
                if st != 0:
                    break

        if st == 0:
            GPS.Project.recompute()  # Add generated files to the project
        yield st

    @staticmethod
    def workflow_compile_context_to_source_code():
        """
        Generate code from the model file for a specific MDL file
        """
        ctxt = GPS.contextual_context() or GPS.current_context()
        return CLI.__compile_files_to_source_code([ctxt.file()])

    @staticmethod
    def workflow_compile_project_to_source_code():
        """
        Generate code for all MDL files in the project
        """
        s = GPS.Project.root().sources(recursive=True)
        return CLI.__compile_files_to_source_code(s)

    @staticmethod
    def workflow_generate_from_mdl_then_build(main_name):
        """
        Generate the code for all simulink files, then compile the project.
        This works best if you have defined the `Main` attribute in your
        project, so that gprbuild knows what to link.
        This is a workflow, and should be used via the functions in
        workflows.py.
        """
        status = yield CLI.workflow_compile_project_to_source_code()
        if status == 0:
            w = TargetWrapper(target_name='Build Main')
            yield w.wait_on_execute(main_name=main_name)

    @staticmethod
    def workflow_generate_from_mdl_then_build_then_debug(main_name):
        """
        Generate the code for all simulink files, then compile the specified
        main, then debug it.
        This is a workflow, and should be used via the functions in
        workflows.py.
        """
        status = yield CLI.workflow_compile_project_to_source_code()
        if status == 0:
            w = TargetWrapper(target_name='Build Main')
            status = yield w.wait_on_execute(main_name=main_name)
        if status == 0:
            f = GPS.File(main_name)
            e = f.project().get_executable_path(f)
            GPS.Debugger.spawn(GPS.File(e))


class QGEN_Diagram(gpsbrowsers.JSON_Diagram):
    def on_selection_changed(self, item, *args):
        """React to a change in selection of an item."""
        pass


class QGEN_Diagram_Viewer(GPS.Browsers.View):
    """
    A Simulink diagram viewer. It might be associated with several
    diagrams, which are used as the user opens blocks.
    """

    file = None   # The associated .mdl file
    diags = None  # The list of diagrams read from this file

    def __init(self):
        self.__events = {}
        super(QGEN_Diagram_Viewer, self).__init__()

    @staticmethod
    def __get_or_create_view(file):
        """
        Get an existing viewer for file, or create a new empty view.
        :return: (view, newly_created)
        """
        for win in GPS.MDI.children():
            if hasattr(win, '_gmc_viewer'):
                v = win._gmc_viewer
                if v.file == file:
                    win.raise_window()
                    return (v, False)

        v = QGEN_Diagram_Viewer()
        v.file = file
        v.diags = None   # a gpsbrowsers.JSON_Diagram_File
        v.create(
            diagram=GPS.Browsers.Diagram(),  # a temporary diagram
            title=os.path.basename(file.name()),
            save_desktop=v.save_desktop)
        v.set_read_only(True)

        c = GPS.MDI.get_by_child(v)
        c._gmc_viewer = v

        return (v, True)

    @staticmethod
    def get_or_create(file, on_loaded=None):
        """
        Get an existing diagram for the file, or create a new one.
        The actual diagrams are loaded asynchronously, so might not be
        available as soon as the instance is constructed. They are however
        automatically loaded in the view as soon as possible.

        :param GPS.File file: the file to display
        :param callable on_loaded: called when the diagram is loaded, or
           immediately if the diagram was already loaded. The funtion
           receives a single parameter, which is the viewer itself.
        :return QGEN_Diagram_Viewer: the viewer.
           It might not contain any diagram yet, since those are read
           asynchronously.
        """
        v, newly_created = QGEN_Diagram_Viewer.__get_or_create_view(file)

        if newly_created:
            def __on_json(json):
                v.diags = GPS.Browsers.Diagram.load_json_data(
                    json, diagramFactory=QGEN_Diagram)
                if v.diags:
                    v.diagram = v.diags.get()

                if on_loaded:
                    on_loaded(v)

            def __on_fail(reason):
                pass

            CLI.get_json(file).then(__on_json, __on_fail)

        else:
            if on_loaded:
                on_loaded(v)

        return v

    @staticmethod
    def open_json(file, data):
        """
        Open an existing JSON file that contains a Simulink diagram.
        :param GPS.File file: the file associated with the JSON data,
           so that we do not open multiple viewers for the same file.
        :param data: the actual json data to display.
        """
        v, newly_created = QGEN_Diagram_Viewer.__get_or_create_view(file)
        if newly_created:
            v.diags = GPS.Browsers.Diagram.load_json_data(
                data, diagramFactory=QGEN_Diagram)
            if v.diags:
                v.diagram = v.diags.get()
        return v

    def save_desktop(self, child):
        """Save the contents of the viewer in the desktop"""
        info = {
            'file': self.file.name(),
            'scale': self.scale,
            'topleft': self.topleft}
        return (module.name(), json.dumps(info))

    def perform_action(self, action, item):
        """
        Perform the action described by the parameter.
        :param str action: an action described in the JSON file, to be
           executed when the user interacts with an item. The list of
           valid actions is documented in the code below.
        """

        # Split the command into its name and arguments
        (name, args) = action.split('(', 1)
        if args and args[-1] != ')':
            GPS.Console().write(
                "Invalid command: %s (missing closing parenthesis)\n" % (
                    action, ))
            return

        args = args[:-1].split(',')  # ??? fails if arguments contain nested ,
        for idx, a in enumerate(args):
            if a[0] in ('"', "'") and a[-1] == a[0]:
                args[idx] = a[1:-1]
            elif a.isdigit():
                args[idx] = int(a)
            else:
                GPS.Console().write("Invalid command: %s\n" % (action, ))
                return

        if name == 'showdiagram':
            self.diagram = self.diags.get(args[0])

    # @overriding
    def on_item_double_clicked(self, topitem, item, x, y, *args):
        """
        Called when the user double clicks on an item.
        """
        action = topitem.data.get('dblclick')
        if action:
            self.perform_action(action, topitem)

    # @overriding
    def on_create_context(self, context, topitem, item, x, y, *args):
        """
        Called when the user right-clicks in an item.
        """
        context.set_file(self.file)
        context.modeling_item = item
        context.modeling_topitem = topitem


class Mapping_File(object):
    """
    Support for the mapping file generated by qgen, which maps from source
    lines to blocks, and back. The format of this mapping file is:
       { "filename.adb": {   # repeated for each file
              "block1": {    # repeated for each block
                  "line": [1, 2],    # lines impacted by this block
                  "symbol": ["s1", "s2"]   # variables from this block
              }
       }
    """

    def __init__(self, filename=None):
        # In the following, a `file` is an instance of `GPS.File`
        self.blocks = {}   # block_id => set([(file,line), (file,line)])
        self.lines = {}    # (file,line) => set([block_id])
        self.files = {}    # sourcefile => mdlfile

    def load(self, mdlfile):
        """
        Load a mapping file from the disk. This cumulates with existing
        information already loaded.
        :param GPS.File mdlfile: the MDL file we start from
        """
        filename = os.path.join(
            project_support.get_output_dir(mdlfile),
            '%s.json' % os.path.basename(mdlfile.name()))

        try:
            f = open(filename)
        except IOError:
            GPS.Console().write('Mapping file %s not found\n' % filename)
            return

        try:
            js = json.load(f)
        except:
            GPS.Console().write('Invalid json in %s\n' % filename)
            return

        for filename, blocks in js.iteritems():
            f = GPS.File(filename)
            self.files[f.name()] = mdlfile

            for blockid, blockinfo in blocks.iteritems():
                for line in blockinfo['lines']:
                    a = self.blocks.setdefault(blockid, set())
                    a.add((f, line))

                    a = self.lines.setdefault((f.name(), line), set())
                    a.add(blockid)

    def get_breakpoints(self, blockid):
        """
        Returns the set of (filename, line) tuples on which we should set or
        remove breakpoints, for a given block.
        """
        return self.blocks.get(blockid, set())

    def get_blocks(self, filename, line):
        """
        The set of block names corresponding to a given source line
        :param str filename:
        """
        return self.lines.get((filename, line), set())

    def get_mdl_file(self, filename):
        """
        Return the name of the MDL file used to generate the given file
        :param str file: the source file
        :return: a `GPS.File`
        """
        return self.files.get(filename, None)


project_support = Project_Support()
project_support.register_languages()  # available before project is loaded

if not CLI.is_available():
    logger.log('mdl2json not found')

else:
    project_support.register_tool()

    class QGEN_Debugger_Support(object):
        """
        Support for interacting with the debugger.
        """

        @staticmethod
        @gps_utils.hook('debugger_started')
        def __on_debugger_started(debugger):
            debugger._modeling_map = Mapping_File()
            for f in GPS.Project.root().sources(recursive=True):
                if CLI.is_model_file(f):
                    debugger._modeling_map.load(f)

        @staticmethod
        @gps_utils.hook('debugger_location_changed')
        def __on_debugger_location_changed(debugger):
            """
            Show the model corresponding to the current editor and line
            """
            filename = debugger.current_file.name()
            line = debugger.current_line

            if filename and hasattr(debugger, '_modeling_map'):
                blocks = debugger._modeling_map.get_blocks(filename, line)
                mdl = debugger._modeling_map.get_mdl_file(filename)

                if mdl:
                    def __on_loaded(viewer):
                        """
                        The diagrams have been loaded from the MDL file
                        """
                        assert isinstance(viewer, QGEN_Diagram_Viewer)

                        # Unselect items from the previous step
                        # ??? Should do the same for all open viewers
                        viewer.diags.clear_selection()

                        # Select the blocks corresponding to the current line

                        for block in blocks:
                            item = viewer.diags.get_diagram_for_item(block)
                            if item:
                                viewer.diagram = item[0]
                                viewer.diagram.select(item[1])

                    QGEN_Diagram_Viewer.get_or_create(
                        mdl, on_loaded=__on_loaded)

        @staticmethod
        def set_breakpoint():
            """
            Set a breakpoint, in the current debugger, on the current block
            """
            ctx = GPS.contextual_context() or GPS.current_context()
            debug = GPS.Debugger.get()
            if debug and hasattr(debug, "_modeling_map"):
                it = ctx.modeling_item
                while it and not hasattr(it, "id"):
                    it = it.parent
                if it:
                    br = debug._modeling_map.get_breakpoints(it.id)
                    if br:
                        for b in br:
                            debug.send("break %s:%s" % (b[0], b[1]))
                    else:
                        GPS.Console().write("No breakpoint for '%s'\n" % it.id)

    class QGEN_Module(modules.Module):

        @staticmethod
        @gps_utils.hook('open_file_action_hook', last=False)
        def __on_open_file_action(file, *args):
            """
            When an ".mdl" file is opened, use a diagram viewer instead of a
            text file to view it.
            """
            if file.language() == 'simulink':
                logger.log('Open %s' % file)
                viewer = QGEN_Diagram_Viewer.get_or_create(file)
                return True
            if file.language() == 'simulink_json':
                logger.log('Open %s' % file)
                viewer = QGEN_Diagram_Viewer.open_json(
                    file, open(file.name()).read())
                return True
            return False

        def load_desktop(self, data):
            """Restore the contents from the desktop"""
            info = json.loads(data)
            f = GPS.File(info['file'])
            if f.name().endswith('.mdl'):
                viewer = QGEN_Diagram_Viewer.get_or_create(f)
            else:
                viewer = QGEN_Diagram_Viewer.open_json(
                    f, open(f.name()).read())
            viewer.scale = info['scale']
            viewer.topleft = info['topleft']
            return GPS.MDI.get_by_child(viewer)

        def __contextual_name_for_break_on_block(self, context):
            debugger = GPS.Debugger.get()
            it = None
            if debugger and hasattr(context, "modeling_item"):
                it = context.modeling_item
                while it and not hasattr(it, "id"):
                    it = it.parent

            if it:
                return 'Debug/Break on block %s' % (
                    it.id.replace("/", "\\/"), )
            else:
                return 'Debug/Break on block'

        def setup(self):
            """
            Initialize the support for modeling in GPS.
            This is only called when the necessary command line executables
            are found.
            """

            gps_utils.make_interactive(
                callback=CLI.workflow_compile_context_to_source_code,
                name='MDL generate code for file',
                category='QGen',
                filter=CLI.is_model_file,
                contextual='Generate code for %f')

            gps_utils.make_interactive(
                callback=CLI.workflow_compile_project_to_source_code,
                name='MDL generate code for whole project',
                category='QGen')

            gps_utils.make_interactive(
                name='MDL break debugger on block',
                contextual=self.__contextual_name_for_break_on_block,
                filter=CLI.is_model_block_and_debugger,
                callback=QGEN_Debugger_Support.set_breakpoint)

            workflows.create_target_from_workflow(
                target_name="MDL Generate code then build",
                workflow_name="generate-from-mdl-then-build",
                workflow=CLI.workflow_generate_from_mdl_then_build,
                icon_name="gps-build-mdl-symbolic")

            workflows.create_target_from_workflow(
                target_name="MDL Generate code then build then debug",
                workflow_name="generate-from-mdl-then-build-then-debug",
                workflow=CLI.workflow_generate_from_mdl_then_build_then_debug,
                icon_name="gps-build-mdl-symbolic",
                in_toolbar=True)

    module = QGEN_Module()