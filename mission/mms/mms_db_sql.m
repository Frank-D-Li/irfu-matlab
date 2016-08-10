classdef mms_db_sql < handle
  %MMS_DB_SQL handle MMS database of files and variables in SQLITE
  %   IN DEVELOPMENT, DO NOT USE YET!!!! (Hopefully soon)

  properties (Access=protected)
    conn = [];
    statement
    PrepStmt
    databaseDirectory
  end
	
  properties
    databaseFile
  end

  properties (Dependent = true)
    isConnected
  end
  
  methods
    function obj = mms_db_sql(fileName)
      % Create or open existing database
      %   m = mms_db_sql('index.db');
      javaPath = [irf('path'), filesep, 'contrib', filesep, 'java', filesep];
      listDir = dir([javaPath, 'sqlite-jdbc*.jar']);
      if(isempty(listDir)), error('Missing sqlite-jdbc.jar'); end
      javaaddpath([javaPath, listDir(end).name]);
      if nargin == 1,
        [dirPath,file,ext] = fileparts(fileName);
        if isempty(dirPath) || strcmp(dirPath,'.')
          dirPath = pwd;
        end
        obj.databaseDirectory = dirPath;
        obj.databaseFile = [dirPath filesep file ext];
        obj.open_database;
      end
    end
    
    function open_database(obj)
      % Create tables if they do not exist
      sql = [ 'PRAGMA foreign_keys = ON;', ...
        'CREATE TABLE IF NOT EXISTS "FileList" (', ...
          '"idFile" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, ', ...
          '"directory",', ...
          '"dataset",', ...
          '"date",', ...
          '"version",', ...
          '"fileNameFullPath" TEXT UNIQUE);', ...
        'CREATE TABLE IF NOT EXISTS "FileListToImport" (', ...
          '"directory",', ...
          '"dataset",', ...
          '"date",', ...
          '"version",', ...
          '"fileNameFullPath" TEXT UNIQUE);', ...
        'CREATE TABLE IF NOT EXISTS "Datasets" (', ...
          '"idDataset" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,', ...
          '"dataset" TEXT,', ...
          '"varNames" TEXT);', ...
        'CREATE TABLE IF NOT EXISTS "VarNames" (', ...
          '"idVar" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,', ...
          '"idDataset" INTEGER, ', ...
          '"varName" TEXT,', ...
          'FOREIGN KEY(idDataset) REFERENCES Datasets(idDataset) ', ...
          'ON UPDATE CASCADE ON DELETE CASCADE );', ...
        'CREATE TABLE IF NOT EXISTS "VarIndex" (', ...
          '"idFile" INTEGER,', ...
          '"idDataset" INTEGER,', ...
          '"startTT" INTEGER,', ...
          '"endTT" INTEGER, ', ...
          'FOREIGN KEY(idFile) REFERENCES FileList(idFile) ', ...
          'ON UPDATE CASCADE ON DELETE CASCADE, ', ...
          'FOREIGN KEY(idDataset) REFERENCES Datasets(idDataset) ',...
          'ON UPDATE CASCADE ON DELETE CASCADE);', ...
            ];
      obj.sqlUpdate(sql);
    end
    
    function connect(obj)
      % CONNECT open connection to database
      if ~obj.isConnected
        d = org.sqlite.JDBC;
        p = java.util.Properties();
        obj.conn = d.createConnection(['jdbc:sqlite:' obj.databaseFile],p);
        obj.statement = obj.conn.createStatement();
      end
    end

    function insertPrepToFileList(obj, filesToImport)
      % insert filesToImport with prepareStatement. Quicker as it does not
      % use that many SQL transactions.
      if ~obj.isConnected, obj.connect(); end
      obj.conn.setAutoCommit(false);
      obj.statement = obj.conn.prepareStatement(['INSERT into FileList ', ...
        '(directory, dataset, date, version, fileNameFullPath) VALUES ', ...
        '(?, ?, ?, ?, ?);']);
      for i = 1:length(filesToImport)
        obj.statement.setString(1, filesToImport{i}.directory);
        obj.statement.setString(2, filesToImport{i}.dataset);
        obj.statement.setString(3, filesToImport{i}.date);
        obj.statement.setString(4, filesToImport{i}.version);
        obj.statement.setString(5, filesToImport{i}.fileNameFullPath);
%        obj.statement.executeUpdate(); Slow when writing many (>1000) entries
        obj.statement.addBatch(); % Quickest solution (as of sqlite-jdbc-3.8.11.2)
      end
      obj.statement.executeBatch();
      obj.conn.commit(); % <-- HERE all SQL transactions etc. are done, may take a while.
      % Reset connection & statement to default statement with autocommit
      obj.conn.setAutoCommit(true);
      obj.statement = obj.conn.createStatement();
    end

    function insertPrepToVarIndex(obj, toImport)
      % INPUT toImport struct with "filesToImport" information and "cdfOut"
      if ~iscell(toImport) || ~isstruct(toImport{1})
        errStr='Unexpected input. Should be a cell with structs';
        irf.log('critical', errStr);
        error(errStr);
      end
      if ~obj.isConnected, obj.connect(); end
      % Disable defualt automatic commit
      obj.conn.setAutoCommit(false);
      
      % Prepared SQL statement
      sql = ['INSERT INTO VarIndex (idFile, idDataset, startTT, endTT)', ...
        ' VALUES ( ', ...
        '(SELECT idFile FROM FileList WHERE fileNameFullPath = ?), ',...
        '(SELECT idDataset FROM Datasets WHERE varNames = ? AND dataset = ?), ',...
        '?, ?);'];

      obj.PrepStmt = obj.conn.prepareStatement(sql);
      
      % Loop through all the files and variables start/stop time to be imported.
      for ii = 1:numel(toImport)
        for jj = 1:numel(toImport{ii}.cdfOut)
          varNames = toImport{ii}.cdfOut(jj).varNames;
          if(ischar(varNames)), varNames={varNames}; end
          varNamesStr = strjoin(sort(varNames), ' ');
          if(isempty(toImport{ii}.cdfOut(jj).startTT) || toImport{ii}.cdfOut(jj).startTT < int64(1000))
            % FPI put energy in DEPEND_0 and some EDP have no main Epoch
            % (created from HK before SCI data was downloaded).
            continue
          elseif(isnan(toImport{ii}.cdfOut(jj).startTT) || isnan(toImport{ii}.cdfOut(jj).endTT))
            startTT = '"NULL"';
            endTT = '"NULL"';
          else
            startTT = num2str(toImport{ii}.cdfOut(jj).startTT);
            endTT = num2str(toImport{ii}.cdfOut(jj).startTT);
          end
          obj.PrepStmt.setString(1, toImport{ii}.fileNameFullPath);
          obj.PrepStmt.setString(2, varNamesStr);
          obj.PrepStmt.setString(3, toImport{ii}.dataset);
          obj.PrepStmt.setString(4, startTT);
          obj.PrepStmt.setString(5, endTT);
          obj.PrepStmt.addBatch(); % Quickest solution..
        end
      end
      obj.PrepStmt.executeBatch();
      obj.conn.commit(); % <-- HERE all SQL transactions etc. are done, may take a while.

      % Reset connection & statement to default statement with autocommit
      obj.conn.setAutoCommit(true);
    end

    function close(obj)
      % CLOSE close connection to database
      obj.conn.close % close connection
      obj.conn = [];
    end

    function value = get.isConnected(obj)
      if isempty(obj.conn)
        value = false;
      else
        value = true;
      end
    end

    function import_a_file_from_list(obj)
      % import one new file from FileListToImport
      sql = ['SELECT * FROM FileListToImport ',...
        'WHERE fileNameFullPath NOT IN ', ...
        '(SELECT fileNameFullPath FROM FileList) ', ...
        'ORDER BY rowid DESC limit 1'];
      rs = obj.sqlQuery(sql);
      while rs.next
        fileToImport = char(rs.getString('fileNameFullPath'));
        fileInfo{1,1} = struct('fileNameFullPath',fileToImport, ...
          'directory', char(rs.getString('directory')), ...
          'dataset', char(rs.getString('dataset')), ...
          'date', char(rs.getString('date')), ...
          'version', char(rs.getString('version')) );
        status = obj.import_files(fileInfo);
        if(status==0)
          irf.log('warning',['Failed to import file: ',fileToImport]);
        end
      end
      if(exist('fileToImport','var'))
        % remove file from FileListToImport
        sql = ['DELETE from FileListToImport ',...
          'WHERE fileNameFullPath="' fileToImport '"'];
        obj.sqlUpdate(sql);
      else
        % No previously files not previously known were found, simply
        % clear FileListToImport
        irf.log('notice','No new files (not already in database) was found.');
        sql = 'DELETE FROM FileListToImport';
        obj.sqlUpdate(sql);
      end
    end
    
    function clear_deleted_files(obj)
      % Clear up database by removing all entries of files which have
      % been deleted.
      irf.log('warning', 'Re-running add_all_files_to_import_list to check which files are present on system.');
      % Clear any old entries in FileListToImport.
      obj.sqlUpdate('DELETE FROM FileListToImport');
      obj.add_all_files_to_import_list;
      % Verify at least some files are found. (ie avoid deleting all entries).
      sql = 'SELECT * FROM FileListToImport ORDER BY rowid LIMIT 1';
      rs = obj.sqlQuery(sql);
      if(~rs.next), irf.log('warning','Nothing found. Aborting.'); return; end
      sql = ['DELETE FROM FileList WHERE idFile IN ',...
        '(SELECT idFile FROM FileList WHERE fileNameFullPath NOT IN ',...
        '(SELECT fileNameFullPath FROM FileListToImport))'];
keyboard; % THIS FUNCTION IS NOT FULLY TESTED, MAKE SURE TO MAKE A BACKUP OF THE DB FILE
      obj.sqlUpdate(sql);
    end

    function clear_unused_files(obj)
      % Clear up database by removing all entries of files which have no
      % entries in the child tables. Note: This can occur as we import all
      % files to the parent table first, then read them one by one and
      % import the read result into the child tables in a batch.
      irf.log('warning', 'Clearing up unused files (i.e. files without children)');
      sql = ['DELETE FROM FileList WHERE idFILE NOT IN ', ...
        '(SELECT idFile FROM VarIndex);'];
keyboard; % THIS FUNCTION IS NOT FULLY TESTED, MAKE SURE TO MAKE A BACKUP OF THE DB FILE
      obj.sqlUpdate(sql);
    end

    function import_files_from_list(obj)
      % import all files from FileListToImport
      someFilesDidNotImport = false;
      sql = ['SELECT * FROM FileListToImport ', ...
        'WHERE fileNameFullPath NOT IN ', ...
        '(SELECT fileNameFullPath FROM FileList) ', ...
        'ORDER BY dataset DESC, date DESC, version ASC'];
      rs = obj.sqlQuery(sql);
      ii = 1;
      while rs.next
        fileToImport = char(rs.getString('fileNameFullPath'));
        fileInfo{ii,1} = struct('fileNameFullPath', fileToImport, ...
          'directory', char(rs.getString('directory')), ...
          'dataset', char(rs.getString('dataset')), ...
          'date', char(rs.getString('date')), ...
          'version', char(rs.getString('version')) ); %#ok<AGROW>
        ii = ii + 1;
      end
      if(exist('fileInfo','var'))
        % We got at least one new file to be imported.
        status = obj.import_files(fileInfo);
        if(status==0), someFilesDidNotImport = true; end
      else
        irf.log('warning','No new files (not already in database) was found.');
        someFilesDidNotImport = true;
      end
      if someFilesDidNotImport
        irf.log('critical','Some files did not import!');
      else
        irf.log('warning','All files imported from FileListToImport.');
      end
      % Clean up FileListToImport
      irf.log('warning','Cleaning up FileListToImport.');
      sql = 'DELETE FROM FileListToImport';
      obj.sqlUpdate(sql);
    end

    function add_all_files_to_import_list(obj)
      % works only in unix or mac
      % Note: This function adds all files found on system to import
      % list, when importing only new (not previously imported files
      % will be processed). This is to allows for deleting files from
      % DB which has been deleted upstream and removed from system.
      % Verify sqlite3 is installed
      [status, ~] = system('command -v sqlite3 >/dev/null 2>&1 || { exit 100; }');
      if(status==100), error('It appears Sqlite3 is not installed/found on your system.'); end
      system(['cd ' obj.databaseDirectory ...
        '; find ./mms[1-4]* -name mms*cdf -type f |  ' ...
        'perl -pe ''s/(\.\/mms.*)(mms[1-4]?_[\w-]*)_(20\d\d\d\d\d\d\d*)_(v[\d\.]*)(.cdf)\n/$1,$2,$3,$4,$_/'' > delme.txt;'...
        'echo -e ".mod csv\n.import delme.txt FileListToImport\n" | sqlite3 ' obj.databaseFile ';'...
        'rm ./delme.txt' ]);
    end

    function status = import_files(obj, filesToImport)
      % Import multiple files at once. (Or as quickly as possible)..
      % return status = 1 if file is imported sucessully, or it exists or
      % file with newer version exists. Otherwise return status = 0.
      if(~iscell(filesToImport) || ~isstruct(filesToImport{1})), error('Unexpected input'); end
      irf.log('notice',['Number of file to import: ' num2str(length(filesToImport))]);
      status = 0; % Assume it did not succeed yet.
      IdFilesToDelete = []; % Keep track of "idFile"(-s) in FileList which are now superseeded.
      % check if files with same data and date exist
      for ii=length(filesToImport):-1:1
        sql = ['SELECT idFile,version FROM FileList ', ...
          'WHERE directory = "' filesToImport{ii}.directory '"', ...
          ' AND dataset = "' filesToImport{ii}.dataset '"', ...
          ' AND date = "' filesToImport{ii}.date '"'];
        rs = obj.sqlQuery(sql);
        if rs.next % file with same dataset and date exists, compare versions
          existingVersion = char(rs.getString('version'));
          if is_version_larger(filesToImport{ii}.version(2:end),existingVersion(2:end))
            irf.log('notice',['File with older version ' existingVersion ' exists!']);
            if(isempty(IdFilesToDelete))
              IdFilesToDelete = char(rs.getString('idFile'));
            else
              IdFilesToDelete = [IdFilesToDelete ', ',char(rs.getString('idFile'))]; %#ok<AGROW>
            end
          else
            irf.log('notice',['Not importing version ', filesToImport{ii}.version, ...
              ' because file with newer version ', existingVersion, ' exists!']);
            filesToImport(ii)=[];
            continue
          end
        end
      end % end of checking for superseded files already existing in DB
      
      % filesToImport contains only new files to be added into the database
      obj.insertPrepToFileList(filesToImport);
      
      toImport = [];
      for ii = length(filesToImport):-1:1
        % Read and process each new file add to VarIndex list
        out = obj.get_science_variables(filesToImport{ii}.fileNameFullPath);
        if isempty(out) % reading cdf file did not succeed
          status = 0;
          % Clean up..
          irf.log('warning', ['Something went wrong reading file: ',filesToImport{ii}.fileNameFullPath]);
          sql = ['DELETE FROM FileList WHERE fileNameFullPath = ', filesToImport{ii}.fileNameFullPath];
          obj.sqlUpdate(sql);
          filesToImport(ii) = [];
          continue;
        end
        
        for iDataset = 1:numel(out)
          if isempty(out(iDataset).startTT) || out(iDataset).startTT<1000, break; end % energy channels are put as DEPEND_0 for FPI
          varNames = out(iDataset).varNames;
          % add dataset to Datasets if needed
          varNamesStr = strjoin(sort(varNames), ' ');
          %SEE IF add_var_names can be improved!
          if( ( ~exist('prevDataset','var') && ~exist('prevVarNames','var') ) || ...
              ( ~strcmp(prevVarNames, varNamesStr) || ...
              ~strcmp(prevDataset, filesToImport{ii}.dataset) ) )
            % Not the same as last iteration, possibly new. Make SQL queries
            idDataset = obj.add_var_names(filesToImport{ii}.dataset, varNames);
            prevDataset = filesToImport{ii}.dataset;
            prevVarNames = varNamesStr;
          end
        end
        
        filesToImport{ii}.cdfOut = out;
        
        if isempty(toImport)
          toImport{1} = filesToImport{ii};
        else
          toImport{end+1} = filesToImport{ii}; %#ok<AGROW>
          if( numel(toImport) >= 1000)
            obj.insertPrepToVarIndex(toImport);
            toImport = [];
          end
        end
        % If we have reached this point then insert went well
        status = 1;
      end % Read and process each new file
      if ~isempty(toImport) % Any remaining files in toImport
        obj.insertPrepToVarIndex(toImport);
      end
      % If any superseeded files was found, delete these (cascade).
      if(~isempty(IdFilesToDelete))
        irf.log('notice', 'Deleting information of superseeded files !');
        sql = ['DELETE FROM FileList WHERE idFile IN (', IdFilesToDelete,')'];
        obj.sqlUpdate(sql);
      end  
    end

    function idDataset = add_var_names(obj, dataset, varNames)
      % ADD_VAR_NAMES add variable names to VarNames table
      if ischar(varNames), varNames = {varNames}; end
      varNamesStr = strjoin(sort(varNames), ' ');
      % Check if dataset with varNames exists
      rs = obj.sqlQuery(['SELECT idDataset FROM Datasets WHERE ', ...
        'varNames="', varNamesStr, '" AND dataset="', dataset, '";']);
      if rs.next
        idDataset = char(rs.getString('idDataset'));
      else
        % Add the new dataset and variables combination and get idDataset
        sql = ['INSERT INTO Datasets(dataset,varNames) VALUES ("', ...
          dataset, '","', varNamesStr, '");'];
        [~, key] = obj.sqlInsertAndReturnLastKey(sql);
        idDataset = num2str(key);
        sqlValues = ['("', strjoin(varNames, ['",', idDataset, '), ("']), ...
          '",', idDataset, ');'];
        sql = ['INSERT OR IGNORE INTO VarNames(varName,idDataset) VALUES', sqlValues];
        obj.sqlUpdate(sql);
      end
    end

    function [idDatasetList,DatasetList] = find_datasets_with_varname(obj, varName)
      % find Datasets with varName
      idDatasetList = {}; iDataset = 1;
      if(nargout==2), DatasetList = {}; end
      sql = ['SELECT idDataset,dataset FROM VarNames LEFT JOIN Datasets ', ...
        'USING (idDataset) WHERE varName = "' varName '"'];
      rs = obj.sqlQuery(sql);
      while rs.next
        idDatasetList{iDataset} = char(rs.getString('idDataset')); %#ok<AGROW>
        if(nargout==2)
          DatasetList{iDataset} =  char(rs.getString('dataset')); %#ok<AGROW>
        end
        iDataset = iDataset + 1;
      end
      if(isempty(idDatasetList))
        irf.log('warning',['There is no variable with name ' varName '.']);
      end  
    end

    function idDatasetList = find_dataset_id(obj, dataset)
      % find Datasets with name "dataset"
      idDatasetList = {}; iDataset = 1;
      sql = ['SELECT idDataset FROM Datasets WHERE dataset = "' dataset '"'];
      rs = obj.sqlQuery(sql);
      while rs.next
        idDatasetList{iDataset} = char(rs.getString('idDataset')); %#ok<AGROW>
        iDataset = iDataset + 1;
      end
      if(isempty(idDatasetList))
        irf.log('warning',['There is no dataset with name ' dataset '.']);
      end
    end

    function tintArray = index_var(obj, varName)
      sql = ['SELECT startTT,endTT FROM VarIndex LEFT JOIN VarNames ', ...
        'USING (idDataset) WHERE VarNames.varName = "' varName '" ',...
        'ORDER BY startTT ASC'];
      rs = obj.sqlQuery(sql);
      tintArray = zeros(0, 2, 'int64');
      while rs.next
        tint = sscanf([char(rs.getString('startTT')) ' ' ...
          char(rs.getString('endTT'))],'%ld %ld');
        tintArray(end+1, :) = tint; %#ok<AGROW>
      end
      if nargout == 0, % print time intervals
        nTint = size(tintArray, 1);
        for ii = 1:min(nTint, 5), disp(irf_time(tintArray(ii,:),'tint>utc')); end
        if nTint>10, disp('...'); end
        for ii = max(5, nTint-5):nTint, disp(irf_time(tintArray(ii,:),'tint>utc')); end
        clear tintArray;
      end
    end

    function res = file_has_var(obj, fileName, varName)
      % find files
      if ischar(varName), varName={varName}; end
      res = true; % default is true
      for iVarname = 1:length(varName)
        varString = varName{iVarname};
        sql = ['select v.idVar from VarNames AS v where v.varName = "' varString '" and ', ...
          'v.idDataset IN (select vind.idDataset from VarIndex AS vind where vind.idFile=', ...
          '(select fl.idFile from FileList AS fl where fl.fileNameFullPath = "' fileName '"))'];
        rs = obj.sqlQuery(sql);
        if ~rs.next
          res = false;
          return;
        end
      end
    end

    function fileNames = find_files(obj, varargin)
      % FIND FILES search files given variable name and/or dataset and/or time interval
      %
      % FIND_FILES(obj,'varName', variableName, ..)
      % FIND_FILES(obj,'dataset', datasetName, ..)
      % FIND__FILES(obj,'tint', tint, ..)
      %  time interval can be UTC string or GenericTimeArray
      %  startTT = int64(0);
      %  endTT = intmax('int64');
      fileNames = cell(0);
      searchTint = false;
      searchVariable = false;
      searchDataset = false;
      args = varargin;
      while numel(args)>=2
        switch lower(args{1})
          case {'tint'}
            timeInterval = args{2};
            [startTT, endTT] = mms_db_sql.start_stop_in_ttns(timeInterval);
            searchTint = true;
          case {'varname', 'variable'}
            varName = args{2};
            if ~ischar(varName)
              irf.log('critical', 'varName should be text string');
              return;
            end
            searchVariable = true;
          case {'dataset','fileprefix'}
            dataset = args{2};
            if ~ischar(dataset)
              irf.log('critical', 'varName should be text string');
              return;
            end
            searchDataset = true;
          otherwise
            irf.log('critical', 'unrecognized input');
            return;
        end
        args(1:2) = [];
      end
      
      if searchTint
        sqlTime = [' AND startTT <= ', num2str(endTT), ...
          ' AND endTT >= ', num2str(startTT) ];
      else
        sqlTime = '';
      end
      % find Datasets with varName
      if ~searchVariable && ~searchDataset
        sqlDataset = 'idDataset ';
      else
        if searchVariable && ~searchDataset
          idDatasetList = find_datasets_with_varname(obj, varName);
        elseif ~searchVariable && searchDataset
          idDatasetList = find_dataset_id(obj, dataset);
        elseif searchVariable && searchDataset
          idDatasetList = intersect(find_datasets_with_varname(obj, varName), find_dataset_id(obj, dataset));
        end
        sqlDataset = ['idDataset IN ("', strjoin(idDatasetList, '","'), '")'];
      end
      % find files
      sql = ['SELECT DISTINCT fileNameFullPath FROM FileList ', ...
        'LEFT JOIN VarIndex USING (idFile) ', ...
        'WHERE ', sqlDataset, sqlTime, ' ORDER BY startTT ASC'];
      rs = obj.sqlQuery(sql);
      while rs.next
        fileNames{end+1} = char(rs.getString('fileNameFullPath')); %#ok<AGROW>
      end
    end

    function var(obj, varargin)
      % VAR seach variable names
      %  VAR('par1', 'par2', ..)
      %  finds variable name which contains a text string par1 and par2 and ...
      sql = 'SELECT * FROM VarNames ';
      if nargin > 1
        sql = [sql 'WHERE '];
        for iVar = 1:nargin-1
          if ischar(varargin{iVar})
            if iVar > 1
              sql = [sql ' AND ']; %#ok<AGROW>
            end
            sql = [sql ' varName like "%' strrep(varargin{iVar},'*','%') '%"']; %#ok<AGROW>
          end
        end
      end
      objName = inputname(1);
      rs = obj.sqlQuery(sql);
      while rs.next
        % disp([char(res.getString('varName'))]);
        varName = char(rs.getString('varName'));
        linkTxt = mms_db_sql.matlab_link(varName, [objName '.var_attributes(''' varName ''')']);
        disp(linkTxt{1});
      end
    end

    function var_attributes(obj, varName)
      fileNameList = obj.find_files('varname', varName);
      fileName = fileNameList{1};
      d = spdfcdfinfo(fileName, 'varstruct', true);
      ivar = ismember(d.Variables.Name, varName);
      varProp = d.Variables;
      fieldN = fieldnames(varProp);
      for ii = 1:numel(fieldN)
        varProp.(fieldN{ii})(~ivar) = [];
      end
      disp '------ VARIABLE PROPERTIES -------';
      disp(varProp);
      varAttr = d.VariableAttributes;
      fieldN = fieldnames(varAttr);
      for ii = 1:numel(fieldN)
        i = strcmp(varName, varAttr.(fieldN{ii})(:,1));
        if isempty(i) || ~any(i)
          varAttr = rmfield(varAttr, fieldN{ii});
        else
          varAttr.(fieldN{ii}) = varAttr.(fieldN{ii})(i,2);
        end
      end
      disp '------ VARIABLE ATTRIBUTES -------';
      disp(varAttr);
    end

    function out = sqlQuery(obj, sql)
      % General function to query SQL
      obj.connect;
      irf.log('debug',['sqlite> ' sql]);
      out = obj.statement.executeQuery(sql);
    end

    function out = sqlUpdate(obj, sql)
      % General function to update SQL, if only one entry is to be inserted
      % consider using sqlInsertAndReturnLastKey.
      obj.connect;
      irf.log('debug',['sqlite> ', sql]);
      out = obj.statement.executeUpdate(sql);
    end

    function [out, key] = sqlInsertAndReturnLastKey(obj, sql)
      % Function to update one SQL table by inserting one row and returning
      % the automatically generated key for that row. Can of course insert
      % multiple rows but a limitation in sqlite-jdbc means only the last
      % key will be returned.
      irf.log('debug', ['sqlite> ', sql, ' with return generated key.']);
      out = obj.statement.executeUpdate(sql);
      rs = obj.statement.getGeneratedKeys();
      if(rs.next)
        key = rs.getLong(1);
        irf.log('debug', ['Inserted new value with Key: ', num2str(key)]);
      else
        errStr = ['Failed to insert and get key! With sql>', sql];
        irf.log('critical', errStr);
        error(errStr);
      end
    end

  end

  methods (Static)

    function out = get_science_variables(cdfFileName)
      % OUT returns structure array with fields
      %     epochVarName - name of the epoch variable, string
      %     varNames - cell array of strings with variables
      %     startTT  - int64 (TT2000 values) with corresponding start time
      %     endTT    - int64 (TT2000 values) with corresponding end time
      narginchk(1,1); % One file name
      if(~exist(cdfFileName, 'file'))
        errStr = ['File not found: ', cdfFileName];
        irf.log('warning', errStr); warning(errStr);
        out = []; return;
      end
      irf.log('debug',['Reading: ' cdfFileName]);
      try
        inf = spdfcdfinfo(cdfFileName, 'VARSTRUCT', true);
      catch ME
        errStr = ['Cannot get file information from: ', cdfFileName];
        irf.log('warning', errStr); irf.log('warning', ME.message);
        warning(errStr); out = []; return;
      end
      dep = inf.VariableAttributes.DEPEND_0;
      [tVarNames, ~, IC] = unique(dep(:,2));
      indGoodTVarName = 1:numel(tVarNames);
      iBadTVarName = ~ismember(tVarNames, inf.Variables.Name); % time variable should be a variable in the cdf file
      if any(iBadTVarName)
        irf.log('notice',['!! bad time variable names in DEPEND_O: ' tVarNames{iBadTVarName}]);
        indGoodTVarName(iBadTVarName) = [];
        tVarNames{iBadTVarName} = [];
      end
      isBadTime = cellfun(@(x) ~any(strcmpi({'tt2000', 'epoch', 'epoch16'}, ...
        inf.Variables.DataType(strcmp(inf.Variables.Name, x)))), ...
        tVarNames(indGoodTVarName));
      if any(isBadTime)
        irf.log('notice',['! not accepted time format for time DEPEND_O variable: ' ...
          tVarNames{indGoodTVarName(isBadTime)}]);
        indGoodTVarName(isBadTime) = [];
      end
      try
        epoch = spdfcdfread(cdfFileName, 'DataOnly', true, ...
          'Variable', tVarNames(indGoodTVarName), ...
          'KeepEpochAsIs', true);
      catch ME
        errStr = ['Cannot read Epochs from file: ', cdfFileName];
        irf.log('warning', errStr); irf.log('warning', ME.message);
        warning(errStr); out = []; return;
      end
      if isinteger(epoch), epoch = {epoch}; end % only one time variable
      for iT = numel(indGoodTVarName):-1:1
        out(iT).epochVarName = tVarNames{iT};
        out(iT).varNames = dep(IC == iT,1);
        startTT = min(epoch{indGoodTVarName(iT)});
        endTT   = max(epoch{indGoodTVarName(iT)});
        if any(startTT) && any(endTT) && ...
            (min(startTT,endTT) < int64(479390467184000000)...% '2015-03-12T00:00:00.000000000'
            ||  max(startTT,endTT) > int64(1262260869184000000)),%'2040-01-01T00:00:00.000000000'
          out(iT).startTT = NaN;
          out(iT).endTT   = NaN;
          irf.log('notice',['!!! In file:', cdfFileName]);
          irf.log('notice',['!!! ', out(iT).epochVarName, ' has startTT = ', ...
            num2str(startTT), ' and endTT = ', num2str(endTT)]);
        else
          out(iT).startTT = startTT;
          out(iT).endTT   = endTT;
        end
      end
    end

    function [startTT, endTT] = start_stop_in_ttns(timeInterval)
      if ischar(timeInterval)
        timeInterval = irf.tint(timeInterval);
      end
      if isa(timeInterval, 'GenericTimeArray')
        startTT = timeInterval.start.ttns;
        endTT = timeInterval.stop.ttns;
      elseif isinteger(timeInterval)
        startTT = timeInterval(1);
        endTT = timeInterval(2);
      else
        irf.log('warning', 'Time interval in unknown format');
        return;
      end
    end

    function fileInfo = get_file_info(fileName)
      % GET_FILE_INFO get values of directory, dataset, date, version
      % fileInfo is structure with fields
      % 'directory','dataset','date',version'
      fileInfo = regexp(fileName,['(?<directory>\.\/mms.*)', ...
        '(?<dataset>mms[1-4]?_[\w-]*)_(?<date>20\d\d\d\d\d\d\d*)', ...
        '_(?<version>v[\d\.]*)(.cdf)'], 'names');
    end

    function outStr=matlab_link(linkText, linkCommandText)
      % MATLAB_LINK returns string with link to matlab text to execute
      % 
      % MATLAB_LINK(linkText, linkCommandText)
      %  linkText can be cell array
      %  In linkCommandText the '?' is substituted with linkText
      if ischar(linkText)
        linkText = {linkText};
      end
      if iscell(linkText)
        outStr = cell(size(linkText));
        for ii = 1:numel(linkText)
          linkStr = linkText{ii};
          linkCommandStr = strrep(linkCommandText, '?', linkStr);
          outStr{ii} = ['<a href="matlab: ', linkCommandStr, '">', linkStr, '</a>' ];
        end
      end
    end

  end

end