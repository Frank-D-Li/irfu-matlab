% Class that collects "processing functions" as public static methods.
%
% This class is not meant to be instantiated.
% 
% Author: Erik P G Johansson, IRF-U, Uppsala, Sweden
% First created 2017-02-10, with source code from data_manager_old.m.
%
%
% CODE CONVENTIONS
% ================
% - It is implicit that arrays/matrices representing CDF data, or "CDF-like" data, using the first MATLAB array index to
%   represent CDF records.
%
%
% SOME INTERMEDIATE PROCESSING DATA FORMATS
% =========================================
% - PreDC = Pre-Demuxing-Calibration Data
%       Generic data format that can represent all forms of input datasets before demuxing and calibration. Can use an
%       arbitrary number of samples per record. Some variables are therefore not used in CWF output datasets.
%       Consists of struct with fields:
%           .Epoch
%           .ACQUISITION_TIME
%           .DemuxerInput : struct with fields.
%               BIAS_1 to .BIAS_5  : NxM arrays, where M may be 1 (1 sample/record) or >1.
%           .freqHz                : Snapshot frequency in Hz. Unimportant for one sample/record data.
%           .DIFF_GAIN
%           .MUX_SET
%           QUALITY_FLAG
%           QUALITY_BITMASK
%           DELTA_PLUS_MINUS
%           % SAMP_DTIME          % Only important for SWF. - Abolished?
%       Fields are "CDF-like": rows=records, all have same number of rows.
% - PostDC = Post-Demuxing-Calibration Data
%       Like PreDC but with additional fields. Tries to capture a superset of the information that goes into any
%       dataset produced by BICAS.
%       Has extra fields:
%           .DemuxerOutput   : struct with fields.
%               V1, V2, V3,   V12, V13, V23,   V12_AC, V13_AC, V23_AC.
%           .IBIAS1
%           .IBIAS2
%           .IBIAS3
%
classdef proc_sub
%#######################################################################################################################
% PROPOSAL: Move out calibration (not demuxing) from proc_sub.
%   PROPOSAL: Reading of calibration files.
%   PROPOSAL: Function for calibrating with either constant factors and transfer functions. (Flag for choosing which.)
%       NOTE: Function needs enough information to split up data into sequences on which transfer functions can be applied.
%
% PROPOSAL: Split into smaller files.
%   PROPOSAL: proc_LFR
%   PROPOSAL: proc_TDS
%   PROPOSAL: proc_demux_calib
%
% PROPOSAL: Use double for all numeric zVariables in the processing. Do not produce or require proper type, e.g. integers, in any
%           intermediate processing. Only convert to the proper data type/class when writing to CDF.
%   PRO: Variables can keep NaN to represent fill/pad value, also for "integers".
%   PRO: The knowledge of the dataset CDF formats is not spread out over the code.
%       Ex: Setting default values for PreDc.QUALITY_FLAG, PreDc.QUALITY_BITMASK, PreDc.DELTA_PLUS_MINUS.
%       Ex: ACQUISITION_TIME.
%   CON: Less assertions can be made in utility functions.
%       Ex: proc_utils.ACQUISITION_TIME_*, proc_utils.tt2000_* functions.
%   CON: ROUNDING ERRORS. Can not be certain that values which are copied, are actually copied.
%   --
%   NOTE: Functions may in principle require integer math to work correctly.
%
% PROPOSAL: Comment section for intermediate PDVs.
% --
% PROPOSAL: Derive DIFF_GAIN (from BIAS HK using time interpolation) in one code common to both LFR & TDS.
%   PROPOSAL: Function
%   PROPOSAL: In intermediate PDV?!
%   PRO: Uses flag for selecting interpolation time in one place.
% PROPOSAL: Derive HK_BIA_MODE_MUX_SET (from BIAS SCI or HK using time interpolation for HK) in one code common to both LFR & TDS.
%   PROPOSAL: Function
%   PROPOSAL: In intermediate PDV?!
%   PRO: Uses flag for selecting HK/SCI DIFF_GAIN in one place.
%   PRO: Uses flag for selecting interpolation time in one place.
%--
% NOTE: Both BIAS HK and LFR SURV CWF contain MUX data (only LFR has one timestamp per snapshot). True also for other input datasets?
%
% PROPOSAL: Every processing function should use a special function for asserting and retrieving the right set of
%           InputsMap keys and values.
%   NOTE: Current convention/scheme only checks the existence of required keys, not absence of non-required keys.
%   PRO: More assertions.
%   PRO: Clearer dependencies.
%
% PROPOSAL: Assertions after every switch statement that differentiates different processing data/dataset versions.
%           Describe what they should all "converge" on, and make sure they actually do.
%
% PROPOSAL: Instantiate class, use instance methods instead of static.
%   PRO: Can have SETTINGS and constants as instance variable instead of calling global variables.
%
% PROPOSAL: Change variable names to conform better with BIAS spec. V1 --> V1_DC
%#######################################################################################################################
    
    methods(Static, Access=public)
        
        function HkSciTime = process_HK_to_HK_on_SCI_TIME(Sci, Hk)
        % Processing function
        
            global SETTINGS
            
            % ASSERTIONS
            EJ_library.utils.assert.struct(Sci, {'ZVars', 'Ga'})
            EJ_library.utils.assert.struct(Hk,  {'ZVars', 'Ga'})
            
            HkSciTime = [];
            
            
            
            % Define local convenience variables. AT = ACQUISITION_TIME
            ACQUISITION_TIME_EPOCH_UTC = SETTINGS.get_fv('PROCESSING.ACQUISITION_TIME_EPOCH_UTC');
            
            hkAtTt2000  = bicas.proc_utils.ACQUISITION_TIME_to_tt2000(  Hk.ZVars.ACQUISITION_TIME, ACQUISITION_TIME_EPOCH_UTC);
            sciAtTt2000 = bicas.proc_utils.ACQUISITION_TIME_to_tt2000( Sci.ZVars.ACQUISITION_TIME, ACQUISITION_TIME_EPOCH_UTC);
            hkEpoch     = Hk.ZVars.Epoch;
            sciEpoch    = Sci.ZVars.Epoch;
            
            %==================================================================
            % Log time intervals to enable comparing available SCI and HK data
            %==================================================================
            bicas.proc_utils.log_tt2000_array('HK  ACQUISITION_TIME', hkAtTt2000)
            bicas.proc_utils.log_tt2000_array('SCI ACQUISITION_TIME', sciAtTt2000)
            bicas.proc_utils.log_tt2000_array('HK  Epoch           ', hkEpoch)
            bicas.proc_utils.log_tt2000_array('SCI Epoch           ', sciEpoch)
            
            %=========================================================================================================
            % 1) Convert time to something linear in time that can be used for processing (not storing time to file).
            % 2) Effectively also chooses which time to use for the purpose of processing:
            %       (a) ACQUISITION_TIME, or
            %       (b) Epoch.
            %=========================================================================================================
            if SETTINGS.get_fv('PROCESSING.USE_AQUISITION_TIME_FOR_HK_TIME_INTERPOLATION')
                bicas.log('info', 'Using HK & SCI zVariable ACQUISITION_TIME (not Epoch) for interpolating HK dataset data to SCI dataset time.')
                hkInterpolationTimeTt2000  = hkAtTt2000;
                sciInterpolationTimeTt2000 = sciAtTt2000;
            else
                bicas.log('info', 'Using HK & SCI zVariable Epoch (not ACQUISITION_TIME) for interpolating HK dataset data to SCI dataset time.')
                hkInterpolationTimeTt2000  = hkEpoch;
                sciInterpolationTimeTt2000 = sciEpoch;
            end
            clear hkAtTt2000 sciAtTt2000
            clear hkEpoch    sciEpoch



            %=========================================================================================================
            % Derive MUX_SET
            % --------------
            % NOTE: Only obtains one MUX_SET per record ==> Can not change MUX_SET in the middle of a record.
            % NOTE: Can potentially obtain MUX_SET from LFR SCI.
            %=========================================================================================================            
            HkSciTime.MUX_SET = bicas.proc_utils.nearest_interpolate_float_records(...
                double(Hk.ZVars.HK_BIA_MODE_MUX_SET), hkInterpolationTimeTt2000, sciInterpolationTimeTt2000);   % Use BIAS HK.
            %PreDc.MUX_SET = LFR_cdf.BIAS_MODE_MUX_SET;    % Use LFR SCI. NOTE: Only possible for ___LFR___.



            %=========================================================================================================
            % Derive DIFF_GAIN
            % ----------------
            % NOTE: Not perfect handling of time when 1 snapshot/record, since one should ideally use time stamps
            % for every LFR _sample_.
            %=========================================================================================================
            HkSciTime.DIFF_GAIN = bicas.proc_utils.nearest_interpolate_float_records(...
                double(Hk.ZVars.HK_BIA_DIFF_GAIN), hkInterpolationTimeTt2000, sciInterpolationTimeTt2000);



            % ASSERTIONS
            EJ_library.utils.assert.struct(HkSciTime, {'MUX_SET', 'DIFF_GAIN'})
        end        
        
        

        function PreDc = process_LFR_to_PreDC(Sci, HkSciTime)
        % Processing function. Convert LFR CDF data to PreDC.
        %
        % Keeps number of samples/record. Treats 1 samples/record "length-one snapshots".
        
        % PROBLEM: Hardcoded CDF data types (MATLAB classes).
        % MINOR PROBLEM: Still does not handle LFR zVar TYPE for determining "virtual snapshot" length.
        % Should only be relevant for V01_ROC-SGSE_L2R_RPW-LFR-SURV-CWF (not V02) which should expire.
        
            % ASSERTIONS
            EJ_library.utils.assert.struct(Sci,        {'ZVars', 'Ga'})
            EJ_library.utils.assert.struct(HkSciTime,  {'MUX_SET', 'DIFF_GAIN'})
            
            sciDvid  = bicas.construct_DVID(Sci.Ga.DATASET_ID{1}, Sci.Ga.Skeleton_version{1});
            nRecords = size(Sci.ZVars.Epoch, 1);
            
            %===========================================================================================================
            % Handle differences between skeletons V01 and V02
            % ------------------------------------------------
            % POTENTIAL,
            % ELECTRICAL : zVars with different names (but identical meaning).
            % L1_REC_NUM : Only seems to have been defined in very old skeletons (not in DataPool git repo).
            %              Abolished for now.
            %===========================================================================================================
            switch(sciDvid)
                case {  'V01_ROC-SGSE_L2R_RPW-LFR-SBM1-CWF', ...
                        'V01_ROC-SGSE_L2R_RPW-LFR-SBM2-CWF', ...
                        'V01_ROC-SGSE_L2R_RPW-LFR-SURV-CWF', ...
                        'V01_ROC-SGSE_L2R_RPW-LFR-SURV-SWF'}
                    POTENTIAL  = Sci.ZVars.POTENTIAL;
                    ELECTRICAL = Sci.ZVars.ELECTRICAL;
                    %L1_REC_NUM = bicas.proc_utils.create_NaN_array([nRecords, 1]);   % Set to fill values.
                case {  'V04_ROC-SGSE_L1R_RPW-LFR-SBM1-CWF-E', ...
                        'V04_ROC-SGSE_L1R_RPW-LFR-SBM2-CWF-E', ...
                        'V04_ROC-SGSE_L1R_RPW-LFR-SURV-CWF-E', ...
                        'V04_ROC-SGSE_L1R_RPW-LFR-SURV-SWF-E'}
                    POTENTIAL  =         Sci.ZVars.V;
                    ELECTRICAL = permute(Sci.ZVars.E, [1,3,2]);
                    % IMPLEMENTATION NOTE: Permuting indices somewhat ugly temporary fix, but it gives(?) backward
                    % compatibility with old datasets (which? /2019-08-23) which have CWF on "snapshot format" (multiple
                    % samples per record), over the second index.
                    
                    %L1_REC_NUM = bicas.proc_utils.create_NaN_array([nRecords, 1]);   % Set to fill values.
                case {  'V02_ROC-SGSE_L2R_RPW-LFR-SBM1-CWF', ...
                        'V02_ROC-SGSE_L2R_RPW-LFR-SBM2-CWF'}
                        %'V02_ROC-SGSE_L2R_RPW-LFR-SURV-CWF'
                        %'V02_ROC-SGSE_L2R_RPW-LFR-SURV-SWF'    % 'V02_ROC-SGSE_L2R_RPW-LFR-SURV-SWF' correct?!
                    POTENTIAL  = Sci.ZVars.V;
                    ELECTRICAL = Sci.ZVars.E;
                    %L1_REC_NUM = Sci.L1_REC_NUM;
                otherwise
                    error('BICAS:proc_sub:SWModeProcessing:Assertion:ConfigurationBug', ...
                        'Can not handle DVID="%s"', sciDvid)
            end

            %========================================================================================
            % Handle differences between datasets with and without zVAR FREQ:
            % LFR_FREQ: Corresponds to FREQ only defined in some LFR datasets.
            %========================================================================================
            switch(sciDvid)
                case {  'V01_ROC-SGSE_L2R_RPW-LFR-SBM1-CWF', ...
                        'V02_ROC-SGSE_L2R_RPW-LFR-SBM1-CWF', ...
                        'V04_ROC-SGSE_L1R_RPW-LFR-SBM1-CWF-E'}
                    FREQ = ones(nRecords, 1) * 1;   % Always value "1" (F1).
                case {  'V01_ROC-SGSE_L2R_RPW-LFR-SBM2-CWF', ...
                        'V02_ROC-SGSE_L2R_RPW-LFR-SBM2-CWF', ...
                        'V04_ROC-SGSE_L1R_RPW-LFR-SBM2-CWF-E'}
                    FREQ = ones(nRecords, 1) * 2;   % Always value "2" (F2).
                case {  'V01_ROC-SGSE_L2R_RPW-LFR-SURV-CWF', ...
                        'V04_ROC-SGSE_L1R_RPW-LFR-SURV-CWF-E', ...
                        'V01_ROC-SGSE_L2R_RPW-LFR-SURV-SWF', ...
                        'V04_ROC-SGSE_L1R_RPW-LFR-SURV-SWF-E'}
                        %'V02_ROC-SGSE_L2R_RPW-LFR-SURV-CWF', ...
                        %'V02_ROC-SGSE_L2R_RPW-LFR-SURV-SWF', ...
                    FREQ = Sci.ZVars.FREQ;
                otherwise
                    error('BICAS:proc_sub:SWModeProcessing:Assertion:ConfigurationBug', ...
                        'Can not handle DVID="%s"', sciDvid)
            end
            
            
            
            nSamplesPerRecord = size(POTENTIAL, 2);
            freqHz            = bicas.proc_utils.get_LFR_frequency( FREQ );   % NOTE: Needed also for 1 SPR.
            
            % Obtain the relevant values (one per record) from zVariables R0, R1, R2, "R3".
            Rx = bicas.proc_utils.get_LFR_Rx( ...
                Sci.ZVars.R0, ...
                Sci.ZVars.R1, ...
                Sci.ZVars.R2, ...
                FREQ );   % NOTE: Function also handles the imaginary zVar "R3".
            
            PreDc = [];
            PreDc.Epoch            = Sci.ZVars.Epoch;
            PreDc.ACQUISITION_TIME = Sci.ZVars.ACQUISITION_TIME;
            PreDc.DELTA_PLUS_MINUS = bicas.proc_utils.derive_DELTA_PLUS_MINUS(freqHz, nSamplesPerRecord);            
            PreDc.freqHz           = freqHz;
            %PreDc.SAMP_DTIME       = bicas.proc_utils.derive_SAMP_DTIME(freqHz, nSamplesPerRecord);
            %PreDc.L1_REC_NUM       = L1_REC_NUM;
            
            
            
            %===========================================================================================================
            % Replace illegally empty data with fill values/NaN
            % -------------------------------------------------
            % IMPLEMENTATION NOTE: QUALITY_FLAG, QUALITY_BITMASK have been found empty in test data, but should have
            % attribute DEPEND_0 = "Epoch" ==> Should have same number of records as Epoch.
            % Can not save CDF with zVar with zero records (crashes when reading CDF). ==> Better create empty records.
            % Test data: MYSTERIOUS_SIGNAL_1_2016-04-15_Run2__7729147__CNES/ROC-SGSE_L2R_RPW-LFR-SURV-SWF_7729147_CNE_V01.cdf
            %
            % PROPOSAL: Move to the code that reads CDF datasets instead. Generalize to many zVariables.
            %===========================================================================================================
            PreDc.QUALITY_FLAG    = Sci.ZVars.QUALITY_FLAG;
            PreDc.QUALITY_BITMASK = Sci.ZVars.QUALITY_BITMASK;
            if isempty(PreDc.QUALITY_FLAG)
                bicas.log('warning', 'QUALITY_FLAG from the LFR SCI source dataset is empty. Filling with empty values.')
                PreDc.QUALITY_FLAG = bicas.proc_utils.create_NaN_array([nRecords, 1]);
            end
            if isempty(PreDc.QUALITY_BITMASK)
                bicas.log('warning', 'QUALITY_BITMASK from the LFR SCI source dataset is empty. Filling with empty values.')
                PreDc.QUALITY_BITMASK = bicas.proc_utils.create_NaN_array([nRecords, 1]);
            end



            % ELECTRICAL must be floating-point so that values can be set to NaN.
            % bicas.proc_utils.filter_rows requires this. Variable may be integer if integer in source CDF.
            ELECTRICAL = single(ELECTRICAL);

            PreDc.DemuxerInput        = [];
            PreDc.DemuxerInput.BIAS_1 = POTENTIAL;
            PreDc.DemuxerInput.BIAS_2 = bicas.proc_utils.filter_rows( ELECTRICAL(:,:,1), Rx==1 );
            PreDc.DemuxerInput.BIAS_3 = bicas.proc_utils.filter_rows( ELECTRICAL(:,:,2), Rx==1 );
            PreDc.DemuxerInput.BIAS_4 = bicas.proc_utils.filter_rows( ELECTRICAL(:,:,1), Rx==0 );
            PreDc.DemuxerInput.BIAS_5 = bicas.proc_utils.filter_rows( ELECTRICAL(:,:,2), Rx==0 );

            PreDc.MUX_SET   = HkSciTime.MUX_SET;
            PreDc.DIFF_GAIN = HkSciTime.DIFF_GAIN;



            % ASSERTIONS
            bicas.proc_sub.assert_PreDC(PreDc)
        end
        
        
        
        function PreDc = process_TDS_to_PreDC(InputsMap)
        % UNTESTED
        %
        % Processing function. Convert TDS CDF data (PDs) to PreDC.
        %
        % Keeps number of samples/record. Treats 1 samples/record "length-one snapshots".
        
        % NOTE: L1_REC_NUM not set in any TDS L2R dataset
        
            SciPd         = InputsMap('SCI_cdf').pd;
            HkOnSciTimePd = InputsMap('HK_on_SCI_time').pd;
            sciPdid       = InputsMap('SCI_cdf').pdid;

            %=====================================================================
            % Handle differences between skeletons V01 and V02
            % ------------------------------------------------
            % LFR_V, LFR_E: zVars with different names (but identical meaning).
            % L1_REC_NUM  : Not defined in V01, but in V02 dataset skeletons.
            %=====================================================================
            switch(sciPdid)
                % Those TDS datasets which have the SAME number of samples/record as in the output datasets.
                case {'V01_ROC-SGSE_L2R_RPW-TDS-LFM-CWF', ...     % 1 S/R
                      'V02_ROC-SGSE_L2R_RPW-TDS-LFM-RSWF'};       % N S/R
                      
                % Those TDS datasets which have DIFFERENT number of samples/record compared to the output datasets.
                case {'V01_ROC-SGSE_L2R_RPW-TDS-LFM-RSWF'}        % 1 S/R for SWF data!!!
                    error('BICAS:proc_sub:SWModeProcessing:Assertion:OperationNotImplemented', ...
                        'This processing function can not interpret PDID=%s. Not implemented yet.', sciPdid)
                otherwise
                    error('BICAS:proc_sub:SWModeProcessing:Assertion:ConfigurationBug', ...
                        'Can not handle PDID="%s"', sciPdid)
            end
            
            nRecords          = size(SciPd.Epoch, 1);
            nSamplesPerRecord = size(SciPd.WAVEFORM_DATA, 3);
            
            freqHz = SciPd.SAMPLING_RATE;
            
            PreDc = [];
            
            PreDc.Epoch            = SciPd.Epoch;
            PreDc.ACQUISITION_TIME = SciPd.ACQUISITION_TIME;
            PreDc.DELTA_PLUS_MINUS = bicas.proc_utils.derive_DELTA_PLUS_MINUS(freqHz, nSamplesPerRecord);            
            PreDc.freqHz           = freqHz;    % CDF_UINT1 ?!!!
            %PreDc.SAMP_DTIME       = bicas.proc_utils.derive_SAMP_DTIME(freqHz, nSamplesPerRecord);
            %PreDc.L1_REC_NUM       = bicas.proc_utils.create_NaN_array([nRecords, nSamplesPerRecord]);   % Set to fill values. Not set in any TDS L2R dataset yet.

            PreDc.QUALITY_FLAG    = SciPd.QUALITY_FLAG;
            PreDc.QUALITY_BITMASK = SciPd.QUALITY_BITMASK;
            
            PreDc.DemuxerInput        = [];
            PreDc.DemuxerInput.BIAS_1 = permute(SciPd.WAVEFORM_DATA(:,1,:), [1,3,2]);
            PreDc.DemuxerInput.BIAS_2 = permute(SciPd.WAVEFORM_DATA(:,2,:), [1,3,2]);
            PreDc.DemuxerInput.BIAS_3 = permute(SciPd.WAVEFORM_DATA(:,3,:), [1,3,2]);
            PreDc.DemuxerInput.BIAS_4 = bicas.proc_utils.create_NaN_array([nRecords, nSamplesPerRecord]);
            PreDc.DemuxerInput.BIAS_5 = bicas.proc_utils.create_NaN_array([nRecords, nSamplesPerRecord]);
            
            PreDc.MUX_SET   = HkOnSciTimePd.MUX_SET;
            PreDc.DIFF_GAIN = HkOnSciTimePd.DIFF_GAIN;
                        
            % ASSERTIONS
            bicas.proc_sub.assert_PreDC(PreDc)
            
            %error('BICAS:proc_sub:OperationNotImplemented', ...
            %    'This processing function process_TDS_to_PreDC has not been implemented yet.')
        end



        function assert_PreDC(PreDc)
            EJ_library.utils.assert.struct(PreDc, {'Epoch', 'ACQUISITION_TIME', 'DemuxerInput', 'freqHz', 'DIFF_GAIN', 'MUX_SET', 'QUALITY_FLAG', ...
                'QUALITY_BITMASK', 'DELTA_PLUS_MINUS'});
            bicas.proc_utils.assert_unvaried_N_rows(PreDc);
            bicas.proc_utils.assert_unvaried_N_rows(PreDc.DemuxerInput);
        end
        
        
        
        function assert_PostDC(PostDc)
            EJ_library.utils.assert.struct(PostDc, {'Epoch', 'ACQUISITION_TIME', 'DemuxerInput', 'freqHz', 'DIFF_GAIN', 'MUX_SET', 'QUALITY_FLAG', ...
                'QUALITY_BITMASK', 'DELTA_PLUS_MINUS', 'DemuxerOutput', 'IBIAS1', 'IBIAS2', 'IBIAS3'});
            bicas.proc_utils.assert_unvaried_N_rows(PostDc);
            bicas.proc_utils.assert_unvaried_N_rows(PostDc.DemuxerOutput);
        end
        

        
        function OutputSci = process_PostDC_to_LFR(SciPostDc, outputDsi, outputVersion)
        % Processing function. Convert PostDC to any one of several similar LFR dataset PDs.
        
            global SETTINGS
            
            % ASSERTIONS
            bicas.proc_sub.assert_PostDC(SciPostDc)            
            
            OutputSci = [];
            
            nSamplesPerRecord = size(SciPostDc.DemuxerOutput.V1, 2);   % Samples per record.
            
            outputDvid = bicas.construct_DVID(outputDsi, outputVersion);
            ZVAR_FN_LIST = {'IBIAS1', 'IBIAS2', 'IBIAS3', 'V', 'E', 'EAC', 'Epoch', ...
                'QUALITY_BITMASK', 'QUALITY_FLAG', 'DELTA_PLUS_MINUS', 'ACQUISITION_TIME'};
            
            switch(outputDvid)
                case  {'V03_ROC-SGSE_L2S_RPW-LFR-SBM1-CWF-E', ...
                       'V03_ROC-SGSE_L2S_RPW-LFR-SBM2-CWF-E', ...
                       'V03_ROC-SGSE_L2S_RPW-LFR-SURV-CWF-E'}
                    
                    %=====================================================================
                    % Convert 1 snapshot/record --> 1 sample/record (if not already done)
                    %=====================================================================
                    OutputSci.Epoch = bicas.proc_utils.convert_N_to_1_SPR_Epoch( ...
                        SciPostDc.Epoch, ...
                        nSamplesPerRecord, ...
                        SciPostDc.freqHz  );
                    OutputSci.ACQUISITION_TIME = bicas.proc_utils.convert_N_to_1_SPR_ACQUISITION_TIME(...
                        SciPostDc.ACQUISITION_TIME, ...
                        nSamplesPerRecord, ...
                        SciPostDc.freqHz, ...
                        SETTINGS.get_fv('PROCESSING.ACQUISITION_TIME_EPOCH_UTC'));
                    
                    OutputSci.DELTA_PLUS_MINUS = bicas.proc_utils.convert_N_to_1_SPR_redistribute( SciPostDc.DELTA_PLUS_MINUS );
                    %OutputSci.L1_REC_NUM       = bicas.proc_utils.convert_N_to_1_SPR_repeat(       SciPostDc.L1_REC_NUM,      nSamplesPerRecord);
                    OutputSci.QUALITY_FLAG     = bicas.proc_utils.convert_N_to_1_SPR_repeat(       SciPostDc.QUALITY_FLAG,    nSamplesPerRecord);
                    OutputSci.QUALITY_BITMASK  = bicas.proc_utils.convert_N_to_1_SPR_repeat(       SciPostDc.QUALITY_BITMASK, nSamplesPerRecord);
                    
                    % Convert PostDc.DemuxerOutput
                    for fn = fieldnames(SciPostDc.DemuxerOutput)'
                        SciPostDc.DemuxerOutput.(fn{1}) = bicas.proc_utils.convert_N_to_1_SPR_redistribute( ...
                            SciPostDc.DemuxerOutput.(fn{1}) );
                    end
                    
                    OutputSci.IBIAS1           = bicas.proc_utils.convert_N_to_1_SPR_redistribute( SciPostDc.IBIAS1 );
                    OutputSci.IBIAS2           = bicas.proc_utils.convert_N_to_1_SPR_redistribute( SciPostDc.IBIAS2 );
                    OutputSci.IBIAS3           = bicas.proc_utils.convert_N_to_1_SPR_redistribute( SciPostDc.IBIAS3 );
                    OutputSci.V(:,1)           = SciPostDc.DemuxerOutput.V1;
                    OutputSci.V(:,2)           = SciPostDc.DemuxerOutput.V2;
                    OutputSci.V(:,3)           = SciPostDc.DemuxerOutput.V3;
                    OutputSci.E(:,1)           = SciPostDc.DemuxerOutput.V12;
                    OutputSci.E(:,2)           = SciPostDc.DemuxerOutput.V13;
                    OutputSci.E(:,3)           = SciPostDc.DemuxerOutput.V23;
                    OutputSci.EAC(:,1)         = SciPostDc.DemuxerOutput.V12_AC;
                    OutputSci.EAC(:,2)         = SciPostDc.DemuxerOutput.V13_AC;
                    OutputSci.EAC(:,3)         = SciPostDc.DemuxerOutput.V23_AC;
                    
                case  'V03_ROC-SGSE_L2S_RPW-LFR-SURV-SWF-E'
                    
                    % ASSERTION
                    if nSamplesPerRecord ~= 2048
                        error('BICAS:proc_sub:Assertion:IllegalArgument', 'Number of samples per CDF record is not 2048, as expected.')
                    end
                    
                    OutputSci.Epoch            = SciPostDc.Epoch;
                    OutputSci.ACQUISITION_TIME = SciPostDc.ACQUISITION_TIME;
                    
                    OutputSci.DELTA_PLUS_MINUS = SciPostDc.DELTA_PLUS_MINUS;
                    %OutputSci.L1_REC_NUM       = PostDc.L1_REC_NUM;
                    OutputSci.QUALITY_BITMASK  = SciPostDc.QUALITY_BITMASK;
                    OutputSci.QUALITY_FLAG     = SciPostDc.QUALITY_FLAG;
                    
                    OutputSci.IBIAS1           = SciPostDc.IBIAS1;
                    OutputSci.IBIAS2           = SciPostDc.IBIAS2;
                    OutputSci.IBIAS3           = SciPostDc.IBIAS3;
                    OutputSci.V(:,:,1)         = SciPostDc.DemuxerOutput.V1;
                    OutputSci.V(:,:,2)         = SciPostDc.DemuxerOutput.V2;
                    OutputSci.V(:,:,3)         = SciPostDc.DemuxerOutput.V3;
                    OutputSci.E(:,:,1)         = SciPostDc.DemuxerOutput.V12;
                    OutputSci.E(:,:,2)         = SciPostDc.DemuxerOutput.V13;
                    OutputSci.E(:,:,3)         = SciPostDc.DemuxerOutput.V23;
                    OutputSci.EAC(:,:,1)       = SciPostDc.DemuxerOutput.V12_AC;
                    OutputSci.EAC(:,:,2)       = SciPostDc.DemuxerOutput.V13_AC;
                    OutputSci.EAC(:,:,3)       = SciPostDc.DemuxerOutput.V23_AC;
                    ZVAR_FN_LIST{end+1} = 'F_SAMPLE';

                    % Only in LFR SWF (not CWF): F_SAMPLE, SAMP_DTIME
                    OutputSci.F_SAMPLE         = SciPostDc.freqHz;
                    %OutputSci.SAMP_DTIME       = PostDc.SAMP_DTIME;
                    
                otherwise
                    error('BICAS:proc_sub:Assertion:IllegalArgument', 'Function can not produce outputDvid=%s.', outputDvid)
            end
            
            
            
            % ASSERTION
            bicas.proc_utils.assert_unvaried_N_rows(OutputSci);
            EJ_library.utils.assert.struct(OutputSci, ZVAR_FN_LIST)
        end   % process_PostDC_to_LFR



        function EOutPD = process_PostDC_to_TDS(InputsMap, eoutPDID)

            %switch(eoutPDID)
            %    case  'V02_ROC-SGSE_L2S_RPW-TDS-LFM-CWF-E'
            %    case  'V02_ROC-SGSE_L2S_RPW-TDS-LFM-RSWF-E'

            error('BICAS:proc_sub:SWModeProcessing:Assertion:OperationNotImplemented', ...
                'This processing function has not been implemented yet.')
        end



        % Processing function. Converts PreDC to PostDC, i.e. demux and calibrate data.
        %
        % Is in large part a wrapper around "simple_demultiplex".
        % NOTE: Public function as opposed to the other demuxing/calibration functions.
        function PostDc = process_demuxing_calibration(PreDc)
        % PROPOSAL: Move setting of IBIASx (bias current) somewhere else?
        %   PRO: Unrelated to demultiplexing.
        %   CON: Related to calibration.

            % ASSERTION
            bicas.proc_sub.assert_PreDC(PreDc);

            %=======
            % DEMUX
            %=======
            PostDc = PreDc;    % Copy all values, to later overwrite a subset of them.
            PostDc.DemuxerOutput = bicas.proc_sub.simple_demultiplex(...
                PreDc.DemuxerInput, ...
                PreDc.MUX_SET, ...
                PreDc.DIFF_GAIN);
            
            %================================
            % Set (calibrated) bias currents
            %================================
            % BUG / TEMP: Set default values since the real values are not available.
            PostDc.IBIAS1 = bicas.proc_utils.create_NaN_array(size(PostDc.DemuxerOutput.V1));
            PostDc.IBIAS2 = bicas.proc_utils.create_NaN_array(size(PostDc.DemuxerOutput.V2));
            PostDc.IBIAS3 = bicas.proc_utils.create_NaN_array(size(PostDc.DemuxerOutput.V3));
            
            % ASSERTION
            bicas.proc_sub.assert_PostDC(PostDc)
        end
        
    end   % methods(Static, Access=public)
            
    %###################################################################################################################
    
    methods(Static, Access=private)
    %methods(Static, Access=public)
        
        % Wrapper around "simple_demultiplex_subsequence" to be able to handle multiple CDF records with changing
        % settings (mux_set, diff_gain).
        %
        % NOTE: NOT a processing function (does not derive a PDV).
        %
        %
        % ARGUMENTS AND RETURN VALUE
        % ==========================
        % DemuxerInput = Struct with fields BIAS_1 to BIAS_5.
        % MUX_SET      = Column vector. Numbers identifying the MUX/DEMUX mode. 
        % DIFF_GAIN    = Column vector. Gains for differential measurements. 0 = Low gain, 1 = High gain.
        %
        %
        % NOTE: Can handle arrays of any size as long as the sizes are consistent.
        function DemuxerOutput = simple_demultiplex(DemuxerInput, MUX_SET, DIFF_GAIN)
        % PROPOSAL: Incorporate into processing function process_demuxing_calibration.
        % PROPOSAL: Assert same nbr of "records" for MUX_SET, DIFF_GAIN as for BIAS_x.
        
            % ASSERTIONS
            EJ_library.utils.assert.struct(DemuxerInput, {'BIAS_1', 'BIAS_2', 'BIAS_3', 'BIAS_4', 'BIAS_5'})
            bicas.proc_utils.assert_unvaried_N_rows(DemuxerInput)
            EJ_library.utils.assert.all_equal([...
                size(MUX_SET,             1), ...
                size(DIFF_GAIN,           1), ...
                size(DemuxerInput.BIAS_1, 1)])

            
            
            % Create empty structure to which new components can be added.
            DemuxerOutput = struct(...
                'V1',     [], 'V2',     [], 'V3',     [], ...
                'V12',    [], 'V23',    [], 'V13',    [], ...
                'V12_AC', [], 'V23_AC', [], 'V13_AC', []);



            %====================================================================
            % Find continuous sequences of records with identical settings, then
            % process data separately (one iteration) for those sequences.
            %====================================================================
            [iFirstList, iLastList] = bicas.proc_utils.find_sequences(MUX_SET, DIFF_GAIN);            
            for iSequence = 1:length(iFirstList)
                
                iFirst = iFirstList(iSequence);
                iLast  = iLastList (iSequence);
                
                % Extract SCALAR settings to use for entire subsequence of records.
                MUX_SET_value   = MUX_SET  (iFirst);
                DIFF_GAIN_value = DIFF_GAIN(iFirst);
                bicas.logf('info', 'Records %2i-%2i : Demultiplexing; MUX_SET=%-3i; DIFF_GAIN=%-3i', ...
                    iFirst, iLast, MUX_SET_value, DIFF_GAIN_value)    % "%-3" since value might be NaN.

                % Extract subsequence of DATA records to "demux".
                DemuxerInputSubseq = bicas.proc_utils.select_row_range_from_struct_fields(DemuxerInput, iFirst, iLast);
                
                %=================================================
                % CALL DEMUXER - See method/function for comments
                %=================================================
                DemuxerOutputSubseq = bicas.proc_sub.simple_demultiplex_subsequence(...
                    DemuxerInputSubseq, MUX_SET_value, DIFF_GAIN_value);
                
                % Add demuxed sequence to the to-be complete set of records.
                DemuxerOutput = bicas.proc_utils.add_rows_to_struct_fields(DemuxerOutput, DemuxerOutputSubseq);
                
            end
            
        end   % simple_demultiplex



        % Demultiplex, with only constant factors for calibration (no transfer functions, no offsets) and exactly one
        % setting for MUX_SET and DIFF_GAIN respectively.
        %
        % This function implements Table 3 and Table 4 in "RPW-SYS-MEB-BIA-SPC-00001-IRF", iss1rev16.
        % Variable names are chosen according to these tables.
        %
        % NOTE/BUG: Does not handle latching relay.
        %
        % NOTE: Conceptually, this function does both (a) demuxing and (b) calibration which could be separated.
        % - Demuxing is done on individual samples at a specific point in time.
        % - Calibration (with transfer functions) is made on a time series (presumably of one variable, but could be several).
        %
        % NOTE: NOT a processing function (does not derive a PDV).
        %
        % NOTE: Function is intended for development/testing until there is proper code for using transfer functions.
        % NOTE: "input"/"output" refers to input/output for the function, which is (approximately) the opposite of
        % the physical signals in the BIAS hardware.
        %
        %
        % ARGUMENTS AND RETURN VALUE
        % ==========================
        % Input     : Struct with fields BIAS_1 to BIAS_5.
        % MUX_SET   : Scalar number identifying the MUX/DEMUX mode.
        % DIFF_GAIN : Scalar gain for differential measurements. 0 = Low gain, 1 = High gain.
        % Output    : Struct with fields V1, V2, V3,   V12, V13, V23,   V12_AC, V13_AC, V23_AC.
        % --
        % NOTE: Will tolerate values of NaN for MUX_SET, DIFF_GAIN. The effect is NaN in the corresponding output values.
        % NOTE: Can handle any arrays of any size as long as the sizes are consistent.
        %
        function Output = simple_demultiplex_subsequence(Input, MUX_SET, DIFF_GAIN)
        %==========================================================================================================
        % QUESTION: How to structure the demuxing?
        % --
        % QUESTION: How split by record? How put together again? How do in a way which
        %           works for real transfer functions? How handle the many non-indexed outputs?
        % QUESTION: How handle changing values of diff_gain, mux_set, bias-dependent calibration offsets?
        % NOTE: LFR data can be either 1 sample/record or 1 snapshot/record.
        % PROPOSAL: Work with some subset of in- and out-values of each type?
        %   PROPOSAL: Work with exactly one value of each type?
        %       CON: Slow.
        %           CON: Only temporary implementation.
        %       PRO: Quick to implement.
        %   PROPOSAL: Work with only some arbitrary subset specified by array of indices.
        %   PROPOSAL: Work with only one row?
        %   PROPOSAL: Work with a continuous sequence of rows/records?
        %   PROPOSAL: Submit all values, and return structure. Only read and set subset specified by indices.
        %
        %
        % PROPOSAL: Could, maybe, be used for demuxing if the caller has already applied the
        %           transfer function calibration on the BIAS signals.
        % PROPOSAL: Validate with some "multiplexer" function?!
        % QUESTION: Does it make sense to have BIAS values as cell array? Struct fields?!
        %   PRO: Needed for caller's for loop to split up by record.
        %
        % QUESTION: Is there some better implementation than giant switch statement?! Something more similar to BIAS
        % specification Table 3-4?
        %
        % QUESTION: MUX modes 1-3 are overdetermined if we always have BIAS1-3?
        %           If so, how select what to calculate?! What if results disagree/are inconsistent? Check for it?
        %
        % PROPOSAL: Separate the multiplication with factor in other function.
        %   PRO: Can use function together with TFs.
        %
        % TODO: Implement demuxing latching relay.
        %==========================================================================================================
            
            global SETTINGS
            
            % ASSERTIONS
            EJ_library.utils.assert.struct(Input, {'BIAS_1', 'BIAS_2', 'BIAS_3', 'BIAS_4', 'BIAS_5'})
            bicas.proc_utils.assert_unvaried_N_rows(Input)
            assert(isscalar(MUX_SET))
            assert(isscalar(DIFF_GAIN))



            ALPHA = SETTINGS.get_fv('PROCESSING.CALIBRATION.SCALAR.ALPHA');
            BETA  = SETTINGS.get_fv('PROCESSING.CALIBRATION.SCALAR.BETA');
            GAMMA = bicas.proc_utils.get_simple_demuxer_gamma(DIFF_GAIN);   % NOTE: GAMMA can be NaN iff DIFF_GAIN is.
            
            % Set default values which will be returned for
            % variables which are not set by the demuxer.
            NAN_VALUES = ones(size(Input.BIAS_1)) * NaN;
            V1_LF     = NAN_VALUES;
            V2_LF     = NAN_VALUES;
            V3_LF     = NAN_VALUES;
            V12_LF    = NAN_VALUES;
            V13_LF    = NAN_VALUES;
            V23_LF    = NAN_VALUES;
            V12_LF_AC = NAN_VALUES;
            V13_LF_AC = NAN_VALUES;
            V23_LF_AC = NAN_VALUES;
            
            % IMPLEMENTATION NOTE: Avoid getting integer - single ==> error.
            Input.BIAS_1 = single(Input.BIAS_1);
            Input.BIAS_2 = single(Input.BIAS_2);
            Input.BIAS_3 = single(Input.BIAS_3);
            Input.BIAS_4 = single(Input.BIAS_4);
            Input.BIAS_5 = single(Input.BIAS_5);

            switch(MUX_SET)
                case 0   % "Standard operation" : We have all information.

                    % Summarize the INPUT DATA we have.
                    V1_DC  = Input.BIAS_1;
                    V12_DC = Input.BIAS_2;
                    V23_DC = Input.BIAS_3;
                    V12_AC = Input.BIAS_4;
                    V23_AC = Input.BIAS_5;
                    % Derive the OUTPUT DATA which are trivial.
                    V1_LF     = V1_DC  / ALPHA;
                    V12_LF    = V12_DC / BETA;
                    V23_LF    = V23_DC / BETA;
                    V12_LF_AC = V12_AC / GAMMA;
                    V23_LF_AC = V23_AC / GAMMA;
                    % Derive the OUTPUT DATA which are less trivial.
                    V13_LF    = V12_LF    + V23_LF;
                    V2_LF     = V1_LF     - V12_LF;
                    V3_LF     = V2_LF     - V23_LF;
                    V13_LF_AC = V12_LF_AC + V23_LF_AC;
                    
                case 1   % Probe 1 fails
                    
                    V2_LF     = Input.BIAS_1 / ALPHA;
                    V3_LF     = Input.BIAS_2 / ALPHA;
                    V23_LF    = Input.BIAS_3 / BETA;
                    % Input.BIAS_4 unavailable.
                    V23_LF_AC = Input.BIAS_5 / GAMMA;
                    
                case 2   % Probe 2 fails
                    
                    V1_LF     = Input.BIAS_1 / ALPHA;
                    V3_LF     = Input.BIAS_2 / ALPHA;
                    V13_LF    = Input.BIAS_3 / BETA;
                    V13_LF_AC = Input.BIAS_4 / GAMMA;
                    % Input.BIAS_5 unavailable.
                    
                case 3   % Probe 3 fails
                    
                    V1_LF     = Input.BIAS_1 / ALPHA;
                    V2_LF     = Input.BIAS_2 / ALPHA;
                    V12_LF    = Input.BIAS_3 / BETA;
                    V12_LF_AC = Input.BIAS_4 / GAMMA;
                    % Input.BIAS_5 unavailable.
                    
                case 4   % Calibration mode 0
                    
                    % Summarize the INPUT DATA we have.
                    V1_DC  = Input.BIAS_1;
                    V2_DC  = Input.BIAS_2;
                    V3_DC  = Input.BIAS_3;
                    V12_AC = Input.BIAS_4;
                    V23_AC = Input.BIAS_5;
                    % Derive the OUTPUT DATA which are trivial.
                    V1_LF     = V1_DC / ALPHA;
                    V2_LF     = V2_DC / ALPHA;
                    V3_LF     = V3_DC / ALPHA;
                    V12_LF_AC = V12_AC / GAMMA;
                    V23_LF_AC = V23_AC / GAMMA;
                    % Derive the OUTPUT DATA which are less trivial.
                    V12_LF    = V1_LF     - V2_LF;
                    V13_LF    = V1_LF     - V3_LF;
                    V23_LF    = V2_LF     - V3_LF;
                    V13_LF_AC = V12_LF_AC + V23_LF_AC;

                case {5,6,7}   % Calibration mode 1/2/3
                    
                    % Summarize the INPUT DATA we have.
                    V12_AC = Input.BIAS_4;
                    V23_AC = Input.BIAS_5;
                    % Derive the OUTPUT DATA which are trivial.
                    V12_LF_AC = V12_AC / GAMMA;
                    V23_LF_AC = V23_AC / GAMMA;
                    % Derive the OUTPUT DATA which are less trivial.
                    V13_LF_AC = V12_LF_AC + V23_LF_AC;
                    
                otherwise
                    if isnan(MUX_SET)
                        ;   % Do nothing. Allow the default values (NaN) to be returned.
                    else
                        error('BICAS:proc_sub:Assertion:IllegalArgument:DatasetFormat', 'Illegal argument value for mux_set.')
                    end
            end   % switch
            
            % Create structure to return. (Removes the "_LF" suffix.)
            Output = [];
            Output.V1     = V1_LF;
            Output.V2     = V2_LF;
            Output.V3     = V3_LF;
            Output.V12    = V12_LF;
            Output.V13    = V13_LF;
            Output.V23    = V23_LF;
            Output.V12_AC = V12_LF_AC;
            Output.V13_AC = V13_LF_AC;
            Output.V23_AC = V23_LF_AC;
            
        end  % simple_demultiplex_subsequence

        
        
        % NEW FUNCTION. NOT USED YET BUT MEANT TO REPLACE OLD FUNCTION "simple_demultiplex_subsequence".
        %
        % (1) Return the information needed for how to calibrate a BIAS-LFR/TDS signal (BIAS_i) that is a function of the demultiplexer mode,
        % (2) Derives as much as possible of all the antenna singles and diffs from the available BIAS-LFR/TDS signals
        % (BIAS_i), except the calibration (i.e. only addition and subtraction).
        %
        % Meant to be called in two different ways, typically twice for any time period with samples.
        % (1) To obtain signal type info needed for how to calibrate every BIAS-LFR/TDS signal (BIAS_i) signal given any demux mode. 
        % (2) To derive the complete set of ASR samples from the given BLTS samples.
        %
        % RATIONALE: Meant to collect all hardcoded information about the demultiplexer routing of signals.
        % NOTE: Does not perform any calibration. The closest is to calculate diffs and singles from diffs and singles.
        % 
        % 
        % ARGUMENTS
        % =========
        % MUX_SET            : Scalar value. Demultiplexer mode.
        % dlrUsing12         : 0/1, true/false. DLR = Demultiplexer Latching Relay.
        %                       False=0 = Using diffs V13_DC, V13_AC
        %                       True =1 = Using diffs V12_DC, V12_AC
        % BltsSamplesCalibVolt : Cell array of matrices, length 5. {iBlts} = Vector with sample values for that channel.
        %                        BIAS calibrated volts.
        % --
        % NOTE: No argument for diff gain since this function does not calibrate.
        %
        %
        % RETURN VALUES
        % =============
        % BltsAsrType : Struct array. (iBlts) = Number representing ASR type of the BLTS data, which depends on the mux mode.
        %               Has fields
        %                   .antennas = Numeric vector of length 0, 1 or 2.
        %                           Either [] (no signal, e.g. BIAS_4/5 for TDS), [iAnt] (single), or [iAnt1, iAnt2] (diff).
        %                           NOTE: iAnt1 < iAnt2. iAnt/iAnt1/iAnt2 = {1,2,3}.
        %                           Represents the current routing of signals.
        %                   .category = String constant representing the category/type of signal on the channel.
        %                           DC single, DC diff, AC low-gain, AC high-gain, no signal
        % AsrSamplesVolt
        %             : All representations of antenna signals which can possibly be derived from the BLTS (BIAS_i).
        %               Struct with fields named as in the BIAS specification: .Vi_LF, .Vij_LF, .Vij_LF_AC
        %               NOTE: Calibration signals GND and 2.5V Ref are also sent to these variables although they are
        %               technically not antenna representations. See implementation.
        %
        %
        % DEFINITIONS
        % ===========
        % BLTS : BIAS-LFR/TDS Signals. Like BIAS_i, i=1..5, but includes various stages of calibration/non-calibration, 
        %        including TM units (inside LFR/TDS), at the physical boundary BIAS-LFR/TDS (BIAS_i; volt), and calibrated
        %        values inside BIAS but before addition and subtraction inside BIAS (after using BIAS offsets, BIAS
        %        transfer functions; volt). NOTE: Partly created to avoid using term "BIAS_i" since it is easily
        %        confused with other things (the subsystem BIAS, bias currents), partly to include various stages of
        %        calibration.
        % ASR  : Antenna Signal Representations. Those measured signals which are ultimately derived/calibrated by BICAS,
        %        i.e. Vi_LF, Vij_LF, Vij_LF_AC (i,j=1..3). 
        %        NOTE: This is different from the physical antenna signals which are
        %        essentially subset of ASR (Vi_LF), was it not for calibration errors and filtering.
        %        NOTE: This is different from the set Vi_DC, Vij_DC, Vij_AC of which a subset are equal to BIAS_i
        %        (which subset it is depends on the demux mode) and which is always in LFR/TDS calibrated volts.
        % BIAS_i, i=1..5 : Defined in BIAS specifications document. Equal to the physical signal at the physical boundary
        %        between BIAS and LFR/TDS. LFR/TDS calibrated volt. Mostly replaced by BLTS+unit in the code.
        %
        function [BltsAsrType, AsrSamplesVolt] ...
                = demultiplexer(MUX_SET, dlrUsing12, BltsSamplesCalibVolt)
            % PROPOSAL: Function name that implies constant settings (MUX_SET at least; DIFF_GAIN?!).
            % PROPOSAL: Convention for separating actual signal data/samples from signal "type".
            %   PROPOSAL: "samples" vs "type"
            % PROPOSAL/NOTE: BIAS calibrated volts = ASR volts (automatically for those ASR for which there is BLTS data)
            % TODO-DECISION: How handle calibration modes with fixed, constant BIAS-LFR/TDS signals?
            %
            % PROBLEM: BltsAsrType.category for AC can not include low-gain/high-gain which leads to different set of
            % alternatives than used for selecting transfer functions.
            % PROPOSAL: "Assertion" for using good combination of mux mode and latching relay. Log warning if assertion
            %           fails.
            % PROPOSAL: Use string constants (calib.m?).
            % PROPOSAL: Assertions for returned string constants.
            
            % ASSERTIONS
            assert(isscalar(MUX_SET))
            assert(isscalar(dlrUsing12))
            assert(iscell(BltsSamplesCalibVolt))
            EJ_library.utils.assert.vector(BltsSamplesCalibVolt)
            assert(numel(BltsSamplesCalibVolt)==5)
            
            % Cv = (BIAS) Calibrated (BLT) volt
            BIAS_1_Cv = BltsSamplesCalibVolt{1};
            BIAS_2_Cv = BltsSamplesCalibVolt{2};
            BIAS_3_Cv = BltsSamplesCalibVolt{3};
            BIAS_4_Cv = BltsSamplesCalibVolt{4};
            BIAS_5_Cv = BltsSamplesCalibVolt{5};
            
            NAN_VALUES = ones(size(BIAS_1_Cv)) * NaN;
            As.V1_LF     = NAN_VALUES;
            As.V2_LF     = NAN_VALUES;
            As.V3_LF     = NAN_VALUES;
            As.V12_LF    = NAN_VALUES;
            As.V13_LF    = NAN_VALUES;
            As.V23_LF    = NAN_VALUES;
            As.V12_LF_AC = NAN_VALUES;
            As.V13_LF_AC = NAN_VALUES;
            As.V23_LF_AC = NAN_VALUES;

            

            if dlrUsing12;   iAntB = 2;
            else             iAntB = 3;
            end
           
            import bicas.proc_sub.routing
            
            % NOTE: BLTS 5 = V23_LF_AC for all modes, but has written it out anyway for completeness.
            switch(MUX_SET)
                case 0   % "Standard operation" : We have all information.

                    % Summarize the routing.
                    [BltsAsrType(1), As] = routing(As, [1],       'DC single', BIAS_1_Cv);
                    [BltsAsrType(2), As] = routing(As, [1,iAntB], 'DC diff',   BIAS_2_Cv);
                    [BltsAsrType(3), As] = routing(As, [2,3],     'DC diff',   BIAS_3_Cv);
                    [BltsAsrType(4), As] = routing(As, [1,iAntB], 'AC',        BIAS_4_Cv);
                    [BltsAsrType(5), As] = routing(As, [2,3],     'AC',        BIAS_5_Cv);
                    
                    % Derive the ASR:s not in the BLTS.
                    if dlrUsing12
                        As.V13_LF    = As.V12_LF    + As.V23_LF;
                        As.V13_LF_AC = As.V12_LF_AC + As.V23_LF_AC;
                    else
                        As.V12_LF    = As.V13_LF    - As.V23_LF;
                        As.V12_LF_AC = As.V13_LF_AC - As.V23_LF_AC;
                    end
                    As.V2_LF     = As.V1_LF     - As.V12_LF;
                    As.V3_LF     = As.V2_LF     - As.V23_LF;
                    
                case 1   % Probe 1 fails

                    [BltsAsrType(1), As] = routing(As, [2],       'DC single', BIAS_1_Cv);
                    [BltsAsrType(2), As] = routing(As, [3],       'DC single', BIAS_2_Cv);
                    [BltsAsrType(3), As] = routing(As, [2,3],     'DC diff',   BIAS_3_Cv);
                    [BltsAsrType(4), As] = routing(As, [1,iAntB], 'AC',        BIAS_4_Cv);
                    [BltsAsrType(5), As] = routing(As, [2,3],     'AC',        BIAS_5_Cv);
                    
                    % NOTE: Can not derive anything for DC. BLTS 1-3 contain redundant data.
                    if dlrUsing12
                        As.V13_LF_AC = As.V12_LF_AC + As.V23_LF_AC;
                    else
                        As.V12_LF_AC = As.V13_LF_AC - As.V23_LF_AC;
                    end
                    
                case 2   % Probe 2 fails
                    
                    [BltsAsrType(1), As] = routing(As, [1],       'DC single', BIAS_1_Cv);
                    [BltsAsrType(2), As] = routing(As, [3],       'DC single', BIAS_2_Cv);
                    [BltsAsrType(3), As] = routing(As, [1,iAntB], 'DC diff',   BIAS_3_Cv);
                    [BltsAsrType(4), As] = routing(As, [1,iAntB], 'AC',        BIAS_4_Cv);
                    [BltsAsrType(5), As] = routing(As, [2,3],     'AC',        BIAS_5_Cv);
                    
                    % NOTE: Can not derive anything for DC. BLTS 1-3 contain redundant data.
                    if dlrUsing12
                        As.V13_LF_AC = As.V12_LF_AC + As.V23_LF_AC;
                    else
                        As.V12_LF_AC = As.V13_LF_AC - As.V23_LF_AC;
                    end
                    
                case 3   % Probe 3 fails
                    
                    [BltsAsrType(1), As] = routing(As, [1],       'DC single', BIAS_1_Cv);
                    [BltsAsrType(2), As] = routing(As, [2],       'DC single', BIAS_2_Cv);
                    [BltsAsrType(3), As] = routing(As, [1,iAntB], 'DC diff',   BIAS_3_Cv);
                    [BltsAsrType(4), As] = routing(As, [1,iAntB], 'AC',        BIAS_4_Cv);
                    [BltsAsrType(5), As] = routing(As, [2,3],     'AC',        BIAS_5_Cv);
                    
                    % NOTE: Can not derive anything for DC. BLTS 1-3 contain redundant data.
                    if dlrUsing12
                        As.V13_LF_AC = V12_LF_AC + V23_LF_AC;
                    else
                        As.V12_LF_AC = V13_LF_AC - V23_LF_AC;
                    end
                    
                case 4   % Calibration mode 0
                    
                    [BltsAsrType(1), As] = routing(As, [1],       'DC single', BIAS_1_Cv);
                    [BltsAsrType(2), As] = routing(As, [2],       'DC single', BIAS_2_Cv);
                    [BltsAsrType(3), As] = routing(As, [3],       'DC single', BIAS_3_Cv);
                    [BltsAsrType(4), As] = routing(As, [1,iAntB], 'AC',        BIAS_4_Cv);
                    [BltsAsrType(5), As] = routing(As, [2,3],     'AC',        BIAS_5_Cv);
                    
                    As.V12_LF    = As.V1_LF    - As.V2_LF;
                    As.V13_LF    = As.V1_LF    - As.V3_LF;
                    As.V23_LF    = As.V2_LF    - As.V3_LF;
                    if dlrUsing12
                        As.V13_LF_AC = As.V12_LF_AC + As.V23_LF_AC;
                    else
                        As.V12_LF_AC = As.V13_LF_AC - As.V23_LF_AC;
                    end

                case {5,6,7}   % Calibration mode 1/2/3
                    
                    switch(MUX_SET)
                        case 5
                            signalTypeCategory = '2.5V Ref';
                        case {6,7}
                            signalTypeCategory = 'GND';
                    end
                    
                    % NOTE: It is in principle arbitrary (probably) how the GND and 2.5V Ref signals, which are
                    % generated by the instrument, should be represented in the datasets, since the datasets assume that
                    % only assumes signals from the antennas. The implementation classifies them as antennas, including
                    % for diffs, but the signalTypeCategory specifies that they should be calibrated differently.
                    [BltsAsrType(1), As] = routing(As, [1],       signalTypeCategory, BIAS_1_Cv);
                    [BltsAsrType(2), As] = routing(As, [2],       signalTypeCategory, BIAS_2_Cv);
                    [BltsAsrType(3), As] = routing(As, [3],       signalTypeCategory, BIAS_3_Cv);
                    [BltsAsrType(4), As] = routing(As, [1,iAntB], 'AC',               BIAS_4_Cv);
                    [BltsAsrType(5), As] = routing(As, [2,3],     'AC',               BIAS_5_Cv);

                    As.V12_LF    = As.V1_LF    - As.V2_LF;
                    As.V13_LF    = As.V1_LF    - As.V3_LF;
                    As.V23_LF    = As.V2_LF    - As.V3_LF;
                    if dlrUsing12
                        As.V13_LF_AC = As.V12_LF_AC + As.V23_LF_AC;
                    else
                        As.V12_LF_AC = As.V13_LF_AC - As.V23_LF_AC;
                    end

                otherwise
%                     if isnan(MUX_SET)
%                         % Do nothing. Allow the default values (NaN) to be returned.
%                     else
                        error('BICAS:proc_sub:Assertion:IllegalArgument:DatasetFormat', 'Illegal argument value for mux_set.')
%                     end
            end   % switch
            
            AsrSamplesVolt = As;
            
            assert(numel(BltsAsrType) == 5)
        end
        
        
        
        % Utility function for "demultiplexer".
        function [BltsAsrType, AsrSamples] = routing(AsrSamples, antennas, category, BltsSamples)
            
            % Normalize vector to row vector since "isequal" is sensitive to row/column vectors.
            antennas = antennas(:)';
            
            % Assign BltsType.
            BltsAsrType.antennas = antennas;
            BltsAsrType.category = category;
            
            % Modify AsrSamples (and assertion on arguments).
            if     isequal(antennas, [1])   && strcmp(category, 'DC single')   AsrSamples.V1_LF     = BltsSamples;
            elseif isequal(antennas, [2])   && strcmp(category, 'DC single')   AsrSamples.V2_LF     = BltsSamples;
            elseif isequal(antennas, [3])   && strcmp(category, 'DC single')   AsrSamples.V3_LF     = BltsSamples;
            elseif isequal(antennas, [1,2]) && strcmp(category, 'DC diff')     AsrSamples.V12_LF    = BltsSamples;
            elseif isequal(antennas, [1,3]) && strcmp(category, 'DC diff')     AsrSamples.V13_LF    = BltsSamples;
            elseif isequal(antennas, [2,3]) && strcmp(category, 'DC diff')     AsrSamples.V23_LF    = BltsSamples;
            elseif isequal(antennas, [1,2]) && strcmp(category, 'AC')          AsrSamples.V12_LF_AC = BltsSamples;
            elseif isequal(antennas, [1,3]) && strcmp(category, 'AC')          AsrSamples.V13_LF_AC = BltsSamples;
            elseif isequal(antennas, [2,3]) && strcmp(category, 'AC')          AsrSamples.V23_LF_AC = BltsSamples;
            else
                error('BICAS:proc_SUB:Assertion:IllegalArgument', 'Illegal combination of arguments antennas and category.')
            end
        end
        
        
        
        % Automatic test code.
        %
        % Very basic tests at this stage. Could be improved but unsure how much is meaningful.
        function demultiplexer___ATEST            
            
            new_test = @(inputs, outputs) (EJ_library.atest.CompareFuncResult(@bicas.proc_sub.demultiplexer, inputs, outputs));
            tl = {};
            
            V1   = 10;
            V2   = 11;
            V3   = 12;
            V12  = V1-V2;
            V13  = V1-V3;
            V23  = V2-V3;
            V12a = 45-56;
            V13a = 45-67;
            V23a = 56-67;

            function AsrSamplesVolt = ASR_samples(varargin)
                assert(nargin == 9)
                AsrSamplesVolt = struct(...
                    'V1_LF',     as(varargin{1}, V1), ...
                    'V2_LF',     as(varargin{2}, V2), ...
                    'V3_LF',     as(varargin{3}, V3), ...
                    'V12_LF',    as(varargin{4}, V12), ...
                    'V13_LF',    as(varargin{5}, V13), ...
                    'V23_LF',    as(varargin{6}, V23), ...
                    'V12_LF_AC', as(varargin{7}, V12a), ...
                    'V13_LF_AC', as(varargin{8}, V13a), ...
                    'V23_LF_AC', as(varargin{9}, V23a));
                
                function V = as(v,V)    % as = assign. Effectively implements ~ternary operator + constant (NaN).
                    if v; V = V;
                    else  V = NaN;
                    end
                end
            end
            
            if 1
                tl{end+1} = new_test({0, true, {V1, V12, V23, V12a, V23a}}, ...
                    {struct(...
                    'antennas', {[1], [1 2], [2 3], [1 2], [2 3]}, ...
                    'category', {'DC single', 'DC diff', 'DC diff', 'AC', 'AC'}), ...
                    ASR_samples(1,1,1, 1,1,1, 1,1,1)});
            end
            
            if 1
                tl{end+1} = new_test({1, false, {V2, V3, V23, V13a, V23a}}, ...
                    {struct(...
                    'antennas', {[2], [3], [2 3], [1 3], [2 3]}, ...
                    'category', {'DC single', 'DC single', 'DC diff', 'AC', 'AC'}), ...
                    ASR_samples(0,1,1, 0,0,1, 1,1,1)});
            end
            
            EJ_library.atest.run_tests(tl)
        end



        % Add probe signals that can be derived from already known probe signals.
        %
        % ARGUMENTS
        % =========
        % probeSignals             : Struct with an arbitrary subset of the fields ... . Fields must have the same array
        % sizes.
        % complementedProbeSignals
%         function ComplementedProbeSignals = complement_probe_signals(ProbeSignals)
%             % TODO: Lägg till helt tomma signaler, NaN.
% %                     % Derive the OUTPUT DATA which are less trivial.
% %                     V13_LF    = V12_LF    + V23_LF;
% %                     V2_LF     = V1_LF     - V12_LF;
% %                     V3_LF     = V2_LF     - V23_LF;
% %                     V13_LF_AC = V12_LF_AC + V23_LF_AC;
% %                     % Derive the OUTPUT DATA which are less trivial.
% %                     V12_LF    = V1_LF     - V2_LF;
% %                     V13_LF    = V1_LF     - V3_LF;
% %                     V23_LF    = V2_LF     - V3_LF;
% %                     V13_LF_AC = V12_LF_AC + V23_LF_AC;
% %                     % Derive the OUTPUT DATA which are less trivial.
% %                     V13_LF_AC = V12_LF_AC + V23_LF_AC;
%             
% %             if can_derive_signal(ProbeSignals, 'V13', 'V12', 'V23')
% %                 ProbeSignals.V13 = 
% %             elseif
% 
%             ProbeSignals = derive_signal_if_possible(ProbeSignals, 'V13', 'V12', 'V23', @(x1,x2) (x1+x2));
%             ProbeSignals = derive_signal_if_possible(ProbeSignals, 'V2',  'V1',  'V12', @(x1,x2) (x1-x2));
%             ComplementedProbeSignals = ProbeSignals;
%             
%             function ProbeSignals = derive_signal_if_possible(ProbeSignals, outputFieldName, inputFieldName1, inputFieldName2, funcPtr)
%                 if isfield(ProbeSignals, inputFieldName1) ...
%                     &&  isfield(ProbeSignals, inputFieldName2) ...
%                     && ~isfield(ProbeSignals, outputFieldName);
%                     ProbeSignals.(outputFieldName) = funcPtr(ProbeSignals.(inputFieldName1), ProbeSignals.(inputFieldName2));
%                 else
%                     ;   % Do nothing. Return the same ProbeSignals.
%                 end
%             end
%         end

    end   % methods(Static, Access=private)
        
end
