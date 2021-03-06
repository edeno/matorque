classdef TorqueJob < handle
properties(Constant, Access=private)
    statemap = containers.Map({'E', 'H', 'Q', 'R', 'T', 'W'}, ...
                              {'done', 'held', 'queued', 'running', ...
                               'transferring', 'waiting'});
end

properties(Access=private)
    conn;
end

properties(SetAccess=private)
    dir;
    tasks;
end

properties(Dependent)
    status;
end

methods
    %% Public interface

    function self = TorqueJob(funcname, varargin)
    %TORQUEJOB Create a new job on the cluster
    %   OBJ = TORQUEJOB(FUNCNAME, ARGS, DIRECTIVES, DEPS) runs FUNCNAME
    %   on the cluster, creating a separate task for each element in the
    %   numeric array, cell array, or cell array of cell arrays ARGS.
    %
    %   DIRECTIVES are Torque directives passed to the scheduler (e.g.
    %   the amount of time the job should take to run).
    %
    %   DEPS determine whether dependencies of the specified function
    %   should be copied to the server. It defaults to true. If DEPS
    %   is false, then no dependencies are copied. The function is
    %   responsible for adding relevant paths using addpath.

        % Validate arguments
        inParser = inputParser;
        inParser.addRequired('funcname', @ischar);
        inParser.addOptional('args', {});
        inParser.addOptional('directives', [], @(x) ischar(x) || iscell(x) || isempty(x));
        inParser.addOptional('deps', true, @islogical);
        inParser.addParameter('workingDir', [], @ischar);
        inParser.addParameter('numOutputs', [], @(x) isnumeric(x) & x >= 0);
        
        inParser.parse(funcname, varargin{:});
        args = inParser.Results.args;
        directives = inParser.Results.directives;
        deps = inParser.Results.deps;
        numOutputs = inParser.Results.numOutputs;
        if isempty(numOutputs),
            numOutputs = nargout(funcname);
        end
        
        argstruct = struct();
        if ~isempty(args) && ~iscell(args)
            if isnumeric(args) || islogical(args)
                args = num2cell(args);
            else
                args = {args};
            end
        end
        for i = 1:numel(args)
            if ~iscell(args{i})
                if isnumeric(args{i}) || islogical(args{i})
                    args{i} = num2cell(args{i});
                else
                    args{i} = args(i);
                end
            end
            argstruct.(sprintf('arg%d', i)) = args{i};
        end

        % Get password
        matorque_config;
        [username, password] = self.credentials(false);
        fprintf('Connecting to server...\n');
        if ~isempty(inParser.Results.workingDir)
            self.dir = sprintf('%s/jobs/%d', inParser.Results.workingDir, randi(2^53-1));
        else
            self.dir = sprintf('jobs/%d', randi(2^53-1));
        end
        while isempty(self.conn)
            config = self.sshconfig();
            config.hostname = HOST;
            config.username = username;
            config.password = password;

            % Connect to server and create a directory to hold our files
            try
                [self.conn, ~] = ssh2_command(config, ['mkdir -p ' self.dir]);
            catch err
                if strcmp(err.identifier, 'SSH2:auth')
                    disp('Incorrect username or password.');
                    [username, password] = self.credentials(true);
                else
                    rethrow(err)
                end
            end
        end

        % Copy dependencies to server
        if deps
            fprintf('Copying function and dependencies to server...\n');
            deps = matlab.codetools.requiredFilesAndProducts(funcname);
            if ~isempty(deps)
                remote_names = cell(1, numel(deps));
                for i = 1:length(deps)
                    [~, name, ext] = fileparts(deps{i});
                    remote_names{i} = [name ext];
                end
                scp_put(self.conn, deps, self.dir, '/', remote_names);
            end
        else
            fprintf('Copying function to server...\n');
            fpath = which(funcname);
            [~, ffilename, ffileext] = fileparts(fpath);
            scp_put(self.conn, fpath, self.dir, '/', [ffilename ffileext]);
        end
        putmat(self, 'arguments.mat', argstruct);

        % Start jobs
        fprintf('Submitting tasks...\n');
        diaryfiles = cell(1, length(args));
        outfiles = cell(1, length(args));
        argstrs = cell(1, length(args));
        for i = 1:numel(args)
            diaryfile = sprintf('%d_diary.txt', i);
            preamble = sprintf(['addpath(fullfile(pwd, ''%s'')); ' ...
                                'load(fullfile(pwd, ''%s/arguments.mat''), ''arg%d'');'], ...
                               self.dir, self.dir, i);
            if numOutputs <= 0
                outfile = [];
                cmd = sprintf('%s; %s(arg%d{:});', preamble, funcname, i);
            else
                outfile = sprintf('%d_output.mat', i);
                cmd = sprintf('%s; out = cell(1, %d); [out{:}] = %s(arg%d{:}); save(''%s/%s'', ''out'', ''-v7.3''); exit;', ...
                              preamble, numOutputs, funcname, i, self.dir, outfile);
            end
            matlab_cmd = sprintf('matlab -nodisplay -singleCompThread -r %s -logfile %s/%s >/dev/null 2>&1', ...
                self.shellesc(cmd), self.dir, diaryfile);
            if ~isempty(directives)
                matlab_cmd = sprintf('#PBS -l %s\n%s', directives, matlab_cmd);
            end
            diaryfiles{i} = diaryfile;
            outfiles{i} = outfile;
            argstrs{i} = sprintf('echo %s | qsub -j oe -o /dev/null -N %s 2>&1', ...
                                 self.shellesc(matlab_cmd), ...
                                 self.shellesc(sprintf('%s_%d', funcname, i)));
        end
        cmd = strjoin(argstrs, sprintf('\n'));
        self.puttxt('command.sh', cmd);
        [~, result] = ssh2_command(self.conn, sprintf('sh %s/command.sh', self.dir));

        % Check for errors
        err = numel(result) ~= numel(argstrs);
        for i = 1:length(result)
            if err
                break
            end
            if ~isempty(find(result{i} == ' ', 1))
                err = true;
            end
        end

        if err
            error('An error occurred starting jobs:\n\n%s', strjoin(result, '\n'));
        end

        % Create process objects
        procs = cell(1, numel(result));
        for i = 1:numel(result)
            procs{i} = TorqueTask(self, result{i}, args{i}, diaryfiles{i}, outfiles{i});
        end
        self.tasks = procs;
    end

    function out = get.status(self)
    %OBJ.STATUS Gets the combined status of all tasks in this job
        out = strjoin(sort(unique(self.taskstatus(self.tasknames()))), '/');
    end

    function kill(self)
    %OBJ.KILL Kill all tasks in this job
        self.taskkill(self.tasknames());
    end

    function cleanup(self)
    %OBJ.CLEANUP() Cleans up all files associated with this job
        assert(strncmp(self.dir, 'jobs/', 5));
        cmd = sprintf('rm -rf %s', self.shellesc(self.dir));
        [~, ~] = ssh2_command(self.conn, cmd);
    end

    %% Semi-private interface
    function delete(self)
    %OBJ.DELETE() Destructor for class; cleans up associated files if done
        if isempty(self.tasks)
            return
        end

        curstatus = self.status;
        if strcmp(curstatus, 'done')
            self.cleanup()
        else
            warning(['TorqueJob was destroyed, but jobs were not complete '...
                    '(status = %s). Not cleaning up files.'], curstatus);
        end
    end

    function out = readtxt(self, fname)
    %OBJ.READTXT(FNAME) Read a text file from the head node
        [~, out] = ssh2_command(self.conn, ['cat ' self.dir '/' fname]);
    end

    function out = readmat(self, fname)
    %OBJ.READMAT(FNAME) Read a MAT file from the head node
        tmp = tempname;
        mkdir(tmp);
        scp_get(self.conn, fname, tmp, self.dir);
        mfile = fullfile(tmp, fname);
        contents = load(mfile);
        delete(mfile);
        rmdir(tmp);
        out = contents.out;
    end

    function puttxt(self, fname, txt)
    %OBJ.PUTTXT(FNAME, TXT) Put text in a file on the head node
        tmp = tempname;
        fid = fopen(tmp, 'w');
        fwrite(fid, txt);
        fclose(fid);
        scp_put(self.conn, tmp, self.dir, '/', fname);
        delete(tmp);
    end

    function putmat(self, fname, struct)
    %OBJ.PUTMAT(FNAME, OBJ) Save a struct to a MAT file on the head node
        tmp = [tempname '.mat'];
        save(tmp, '-struct', 'struct');
        scp_put(self.conn, tmp, self.dir, '/', fname);
        delete(tmp);
    end

    function status = taskstatus(self, jobids)
    %TASKSTATUS(SELF, JOBIDS) Get status of task or tasks
        % Get job info as XML
        if iscell(jobids)
            celljobs = jobids;
        else
            celljobs = {jobids};
        end
        [~, status] = ssh2_command(self.conn, ['qstat -x ' strjoin(celljobs, ' ')]);
        map = containers.Map();

        if numel(status) > 1 || ~isempty(status{1})
            docbuilder = javax.xml.parsers.DocumentBuilderFactory.newInstance().newDocumentBuilder();
            for i = 1:numel(status)
                % Parse XML into document
                buffer = java.io.StringBufferInputStream(status{i});
                doc = docbuilder.parse(buffer);

                % Parse out job ID and state
                xpath = javax.xml.xpath.XPathFactory.newInstance().newXPath();
                jobid = xpath.evaluate('/Data/Job//text()[1]', doc);
                jobstate = xpath.evaluate('/Data/Job/job_state', doc);
                map(char(jobid)) = char(jobstate);
            end
        end

        % Match each job with an entry, or else assume finished
        status = cell(1, numel(celljobs));
        for i = 1:numel(celljobs)
            if map.isKey(celljobs{i})
                state = map(celljobs{i});
            else
                state = 'E';
            end
            status{i} = self.statemap(state);
        end

        if ~iscell(jobids)
            status = status{1};
        end
    end

    function taskkill(self, jobid)
    %TASKKILL(SELF, JOBID) Kills task or tasks
        if iscell(jobid)
            jobid = strjoin(jobid, ' ');
        end
        [~, ~] = ssh2_command(self.conn, ['qdel ' jobid]);
    end
end

methods(Static, Access=private)
    function [outlogin, outpassword] = credentials(forceauth)
    %TORQUEJOB.CREDENTIALS(FORCEAUTH) Get login and password
        persistent login password;

        if forceauth || isempty(login) || isempty(password)
            matorque_config;

            if isempty(USERNAME)
                [login, password] = logindlg('Title', ['Credentials for ' HOST]);
            else
                login = USERNAME;
                password = logindlg('Title', ['Password for ' USERNAME '@' HOST]);
            end

            if isempty(login) && isempty(password)
                error('User cancelled');
            end
        end

        outlogin = login;
        outpassword = password;
    end

    function escaped = shellesc(arg)
    %TORQUEJOB.SHELLESC(ARG) Escape command-line argument
        escaped = sprintf('''%s''', strrep(arg, '''', '''\'''''));
    end

    function ssh2_struct = sshconfig()
        ssh2_struct = struct();

        ssh2_struct.hostname = [];
        ssh2_struct.username = [];
        ssh2_struct.password = [];
        ssh2_struct.port = 22;

        ssh2_struct.connection = [];
        ssh2_struct.authenticated = 0;
        ssh2_struct.autoreconnect = 0;
        ssh2_struct.close_connection = 0;

        ssh2_struct.pem_file = [];
        ssh2_struct.pem_private_key = [];
        ssh2_struct.pem_private_key_password = [];

        ssh2_struct.command = [];
        ssh2_struct.command_session = [];
        ssh2_struct.command_ignore_response = 0;
        ssh2_struct.command_result = [];

        ssh2_struct.sftp = 0;
        ssh2_struct.scp = 0;
        ssh2_struct.sendfiles = 0;
        ssh2_struct.getfiles = 0;

        ssh2_struct.remote_file = [];
        ssh2_struct.local_target_direcory = [];
        ssh2_struct.local_file = [];
        ssh2_struct.remote_target_direcory = [];
        ssh2_struct.remote_file_new_name = [];
        ssh2_struct.remote_file_mode = 0600; %0600 is default

        ssh2_struct.verified_config = 0;
        ssh2_struct.ssh2_java_library_loaded = 1;

        jar = fullfile(fileparts(mfilename('fullpath')), 'ssh2', 'ganymed-ssh2-m1', 'ganymed-ssh2-m1.jar');
        if ~ismember(jar, javaclasspath)
            javaaddpath(jar);
        end
    end
end

methods(Access=private)
    function out = tasknames(self)
    %TASKNAMES(SELF) Kill task or tasks
        out = cellfun(@(x) x.name, self.tasks, 'UniformOutput', false);
    end
end
end
