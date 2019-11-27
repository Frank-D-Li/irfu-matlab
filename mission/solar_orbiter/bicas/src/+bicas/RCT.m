%
% Class that collects functions related to finding/selecting and reading RCTs.
%
%
% Author: Erik P G Johansson, IRF-U, Uppsala, Sweden
% First created 2019-11-15
%
classdef RCT
% BOGIQ: RCT-reading functions
% ============================
% PROPOSAL: Use same code/function for reading calibration table, as for reading dataset (and master cdfs)?
% PROPOSAL: Assert CDF skeleton/master version number.
% PROPOSAL: Assert skeleton/master.
% PROPOSAL: Assert/warn (depending on setting?) file units.
% PROPOSAL: Only use units in variable names.
% PROPOSAL: Use utility function for reading every zVariable.
%   PROPOSAL: Assert units from zVar attributes.



    properties(Access=private, Constant)
        
        % Minimum number of numerator or denominator coefficients in the BIAS RCT.
        N_MIN_TF_NUMER_DENOM_COEFFS = 8;
        
        % Minimum number of entries in tabulated transfer functions in RCTs.
        TF_TABLE_MIN_LENGTH = 10;
        
    end


    
    methods(Static, Access=public)
        
        
        
        % Determine the path to the RCT that should be used, using the filenaming convention specified in the
        % documentation (defined in SETTINGS), and according to algorithm specified in the documentation.
        %
        % Effectively a wrapper around bicas.RCT.find_RCT_regexp.
        %
        %
        % ARGUMENTS
        % =========
        % pipelineId, rctId : String constants representing pipeline and RCT to be read.
        %
        function RctCalibData = find_RCT_by_SETTINGS_regexp(calibrationDir, pipelineId, rctId, SETTINGS)

            %============================
            % Create regexp for filename
            %============================
            pipelineSettingsSegm = EJ_library.utils.translate({...
                {'ROC-SGSE', 'RGTS'}, 'RGTS';...
                {'RODP'},             'RODP'}, ...
                pipelineId, ...
                'BICAS:calib:Assertion:IllegalArgument', sprintf('Illegal pipelineId="%s"', pipelineId));
            % IMPLEMENTATION NOTE: Below translation statement
            % (1) verifies the argument, AND
            % (2) separates the argument string constants from the SETTINGS naming convention.
            analyzerSettingsSegm = EJ_library.utils.translate({...
                {'BIAS'},     'BIAS'; ...
                {'LFR'},      'LFR'; ...
                {'TDS-CWF'},  'TDS-LFM-CWF'; ...
                {'TDS-RSWF'}, 'TDS-LFM-RSWF'}, ...
                rctId, 'BICAS:calib:Assertion:IllegalArgument', sprintf('Illegal rctId="%s"', rctId));
            filenameRegexp = SETTINGS.get_fv(sprintf('PROCESSING.RCT_REGEXP.%s.%s', pipelineSettingsSegm, analyzerSettingsSegm));
            
            RctCalibData = bicas.RCT.find_RCT_regexp(calibrationDir, filenameRegexp);
        end



        % Determine the path to the RCT that should be used according to algorithm specified in the documentation(?). If
        % there are multiple matching candidates, choose the latest one as indicated by the filename.
        %
        %
        % IMPLEMENTATION NOTES
        % ====================
        % Useful to have this as separate functionality so that the chosen RCT to use can be explicitly overridden via
        % e.g. settings.
        %
        function path = find_RCT_regexp(calibrationDir, filenameRegexp)

            %=================================================
            % Find candidate files and select the correct one
            %=================================================
            dirObjectList = dir(calibrationDir);
            dirObjectList([dirObjectList.isdir]) = [];    % Eliminate directories.
            filenameList = {dirObjectList.name};
            filenameList(~EJ_library.utils.regexpf(filenameList, filenameRegexp)) = [];    % Eliminate non-matching filenames.
            
            % ASSERTION / WARNING
            if numel(filenameList) == 0
                % ERROR
                error('BICAS:calib:CannotFindRegexMatchingRCT', ...
                    'Can not find any calibration file that matches regular expression "%s" in directory "%s".', ...
                    filenameRegexp, calibrationDir);
            end
            % CASE: There is at least one candidate file.
            
            filenameList = sort(filenameList);
            filename     = filenameList{end};
            path         = fullfile(calibrationDir, filename);
            
            if numel(filenameList) > 1
                % WARNING/INFO/NOTICE
                msg = sprintf(...
                    ['Found multiple calibration files matching regular expression "%s"\n', ...
                     'in directory "%s".\n', ...
                     'Selecting the latest one as indicated by the filename: "%s".\n'], ...
                    filenameRegexp, calibrationDir, filename);
                for i = 1:numel(filenameList)
                    msg = [msg, sprintf('    %s\n', filenameList{i})];
                end
                bicas.log('debug', msg)
            end
            
            % IMPLEMENTATION NOTE: Not logging which calibration file is selected, since this function is not supposed
            % to actually load the content.
        end



        function [Bias] = read_BIAS_RCT(filePath)
            % TODO-DECISION: How handle time?
            %   PROPOSAL: "Only" access the BIAS values (trans.func and other) through a function instead of selecting indices in a data struct.
            %       PROPOSAL: (private method) [omegaRps, zVpc] = get_transfer_func(epoch, signalType)
            %           signalType = 'DC single' etc
            
            Do = dataobj(filePath);
            
            % Constants for interpreting the array indices in the CDF.
            NUMERATOR   = 1;
            DENOMINATOR = 2;
            %
            DC_SINGLE = 1;
            DC_DIFF   = 2;
            AC_LG     = 3;
            AC_HG     = 4;
            
            try
                % NOTE: Assumes 1 CDF record or many (time-dependent values).
                % ==> Must handle that dataobj assigns differently for these two cases.
                epochL                   = bicas.RCT.norm_do_zv(Do.data.Epoch_L);
                epochH                   = bicas.RCT.norm_do_zv(Do.data.Epoch_H);
                biasCurrentOffsetsAmpere = bicas.RCT.norm_do_zv(Do.data.BIAS_CURRENT_OFFSET);      % DEPEND_0 = Epoch_L
                biasCurrentGainsApc      = bicas.RCT.norm_do_zv(Do.data.BIAS_CURRENT_GAIN);        % DEPEND_0 = Epoch_L
                dcSingleOffsetsVolt      = bicas.RCT.norm_do_zv(Do.data.V_OFFSET);                 % DEPEND_0 = Epoch_H
                dcDiffOffsetsVolt        = bicas.RCT.norm_do_zv(Do.data.E_OFFSET);                 % DEPEND_0 = Epoch_H
                tfCoeffs                 = bicas.RCT.norm_do_zv(Do.data.TRANSFER_FUNCTION_COEFFS); % DEPEND_0 = Epoch_L

                nEpochL = size(epochL, 1);
                nEpochH = size(epochH, 1);

                % IMPLEMENTATION NOTE: Corrects for what seems to be a bug in dataobj. dataobj permutes/removes indices,
                % and permutes them differently depending on the number of CDF records (but wrong in all cases).
                %
                % 1 CDF record : cdfdump: "TRANSFER_FUNCTION_COEFFS CDF_DOUBLE/1   3:[2,8,4]       F/TTT"   # 3=number of dimensions/record
                % 2 CDF records: cdfdump: "TRANSFER_FUNCTION_COEFFS CDF_DOUBLE/1   3:[2,8,4]       T/TTT"
                % 1 CDF record:   size(Do.data.TRANSFER_FUNCTION_COEFFS.data) == [  4 2 8]
                % 2 CDF records:  size(Do.data.TRANSFER_FUNCTION_COEFFS.data) == [2 4 2 8]                
                tfCoeffs = permute(tfCoeffs, [1, 4,3,2]);



                %=======================================================
                % ASSERTIONS: Size of tfCoeffs/TRANSFER_FUNCTION_COEFFS
                %=======================================================
                assert(size(tfCoeffs, 1) == nEpochL)
                assert(size(tfCoeffs, 2) >= bicas.RCT.N_MIN_TF_NUMER_DENOM_COEFFS)
                assert(size(tfCoeffs, 3) == 2)
                assert(size(tfCoeffs, 4) == 4)

                %================================
                % Assign struct that is returned
                %================================
                Bias.epochL = epochL;
                Bias.epochH = epochH;
                
                Bias.Current.offsetsAmpere   = biasCurrentOffsetsAmpere;
                Bias.Current.gainsApc        = biasCurrentGainsApc;
                Bias.dcSingleOffsetsVolt     = dcSingleOffsetsVolt;
                Bias.DcDiffOffsets.E12Volt   = dcDiffOffsetsVolt(:, 1);
                Bias.DcDiffOffsets.E13Volt   = dcDiffOffsetsVolt(:, 2);
                Bias.DcDiffOffsets.E23Volt   = dcDiffOffsetsVolt(:, 3);
                
                % NOTE: Using name "ItfSet" only to avoid "Itfs" (plural). (List, Table would be wrong? Use "ItfTable"?)
                Bias.ItfSet.DcSingle = bicas.RCT.create_ITF_sequence(...
                    tfCoeffs(:, :, NUMERATOR,   DC_SINGLE), ...
                    tfCoeffs(:, :, DENOMINATOR, DC_SINGLE));
                
                Bias.ItfSet.DcDiff = bicas.RCT.create_ITF_sequence(...
                    tfCoeffs(:, :, NUMERATOR,   DC_DIFF), ...
                    tfCoeffs(:, :, DENOMINATOR, DC_DIFF));
                
                Bias.ItfSet.AcLowGain = bicas.RCT.create_ITF_sequence(...
                    tfCoeffs(:, :, NUMERATOR,   AC_LG), ...
                    tfCoeffs(:, :, DENOMINATOR, AC_LG));
                
                Bias.ItfSet.AcHighGain = bicas.RCT.create_ITF_sequence(...
                    tfCoeffs(:, :, NUMERATOR,   AC_HG), ...
                    tfCoeffs(:, :, DENOMINATOR, AC_HG));
                
                % ASSERTION
                EJ_library.utils.assert.all_equal(...
                   [numel(Bias.ItfSet.DcSingle), ...
                    numel(Bias.ItfSet.DcDiff), ...
                    numel(Bias.ItfSet.AcLowGain), ...
                    numel(Bias.ItfSet.AcHighGain)])
                
                %==========================================================================
                % ASSERTIONS: All variables NOT based on tfCoeffs/TRANSFER_FUNCTION_COEFFS
                %==========================================================================
                bicas.proc_utils.assert_Epoch(Bias.epochL)
                bicas.proc_utils.assert_Epoch(Bias.epochH)
                validateattributes(Bias.epochL, {'numeric'}, {'increasing'})
                validateattributes(Bias.epochH, {'numeric'}, {'increasing'})
                
                assert(ndims(Bias.Current.offsetsAmpere)    == 2)
                assert(size( Bias.Current.offsetsAmpere, 1) == nEpochL)
                assert(size( Bias.Current.offsetsAmpere, 2) == 3)
                assert(ndims(Bias.Current.gainsApc)         == 2)
                assert(size( Bias.Current.gainsApc, 1)      == nEpochL)
                assert(size( Bias.Current.gainsApc, 2)      == 3)
                assert(ndims(Bias.dcSingleOffsetsVolt)      == 2)
                assert(size( Bias.dcSingleOffsetsVolt, 1)   == nEpochH)
                assert(size( Bias.dcSingleOffsetsVolt, 2)   == 3)
                for fn = fieldnames(Bias.DcDiffOffsets)'
                    assert(iscolumn(Bias.DcDiffOffsets.(fn{1}))           )
                    assert(length(  Bias.DcDiffOffsets.(fn{1})) == nEpochH)
                end
                
            catch Exc
                error('BICAS:calib:FailedToReadInterpretRCT', 'Can not interpret calibration file (RCT) "%s"', filePath)
            end
        end



        % LfrItfTable : {iFreq}{iBiasChannel}, iFreq=1..4 representing LFR sampling frequencies F0...F3,
        %                   iFreq=1..3 : iBiasChannel=1..5 for BIAS_1..BIAS_5
        %                   iFreq=4    : iBiasChannel=1..3 for BIAS_1..BIAS_3
        %                  NOTE: This is different from LFR zVar FREQ.
        function LfrItfTable = read_LFR_RCT(filePath, tfExtrapolateAmountHz)
            Do = dataobj(filePath);
            
            try
                % ASSUMPTION: Exactly 1 CDF record.
                % IMPLEMENTATION NOTE: Does not want to rely one dataobj special behaviour for 1 record case
                % ==> Remove leading singleton dimensions, much assertions.

                % NOTE: There are separate TFs for each BLTS channel, not just separate LFR sampling frequencies, i.e.
                % there are 5+5+5+3 TFs (but only 1 frequency table/LSF, since they are recycled).
                % NOTE: The assignment of indices here effectively determines the translation between array index and
                % LFR Sampling Frequency (LSF). This is NOT the same as the values in the LFR zVar FREQ.
                freqTableHz{1}  = shiftdim(Do.data.Freqs_F0.data);    % NOTE: Index {iLfrFreq}.
                freqTableHz{2}  = shiftdim(Do.data.Freqs_F1.data);
                freqTableHz{3}  = shiftdim(Do.data.Freqs_F2.data);
                freqTableHz{4}  = shiftdim(Do.data.Freqs_F3.data);

                amplTableCpv{1}  = shiftdim(Do.data.TF_BIAS_12345_amplitude_F0.data);
                amplTableCpv{2}  = shiftdim(Do.data.TF_BIAS_12345_amplitude_F1.data);
                amplTableCpv{3}  = shiftdim(Do.data.TF_BIAS_12345_amplitude_F2.data);
                amplTableCpv{4}  = shiftdim(Do.data.TF_BIAS_123_amplitude_F3.data);

                phaseTableDeg{1} = shiftdim(Do.data.TF_BIAS_12345_phase_F0.data);
                phaseTableDeg{2} = shiftdim(Do.data.TF_BIAS_12345_phase_F1.data);
                phaseTableDeg{3} = shiftdim(Do.data.TF_BIAS_12345_phase_F2.data);
                phaseTableDeg{4} = shiftdim(Do.data.TF_BIAS_123_phase_F3.data);

                for iLsf = 1:4
                    if iLsf ~= 4
                        nBltsChannels = 5;
                    else
                        nBltsChannels = 3;
                    end

                    % NOTE: Values for the specific LFS, hence the prefix.
                    lsfFreqTableHz   = freqTableHz{iLsf};
                    lsfAmplTableCpv  = amplTableCpv{iLsf};
                    lsfPhaseTableDeg = phaseTableDeg{iLsf};

                    % ASSERTIONS: Check CDF array sizes, and implicitly that the CDF format is the expected one.
                    assert(iscolumn(freqTableHz{iLsf}))
                    
                    assert(ndims(lsfAmplTableCpv)  == 2)
                    assert(ndims(lsfPhaseTableDeg) == 2)
                    assert(size( lsfAmplTableCpv,  1) >= bicas.RCT.TF_TABLE_MIN_LENGTH)
                    assert(size( lsfPhaseTableDeg, 1) >= bicas.RCT.TF_TABLE_MIN_LENGTH)
                    assert(size( lsfAmplTableCpv,  2) == nBltsChannels)
                    assert(size( lsfPhaseTableDeg, 2) == nBltsChannels)

                    for iBltsChannel = 1:nBltsChannels
                        
                        lsfBltsFreqTableHz   = lsfFreqTableHz;
                        lsfBltsAmplTableCpv  = lsfAmplTableCpv( :, iBltsChannel);
                        lsfBltsPhaseTableDeg = lsfPhaseTableDeg(:, iBltsChannel);
                        
                        % Extrapolate the TF somewhat to higher frequencies
                        % -------------------------------------------------
                        % IMPLEMENTATION NOTE: This is needed since calibrating CWF data needs transfer function values
                        % for slightly higher frequencies than tabulated in the RCT.
                        [~, lsfBltsAmplTableCpv] = bicas.utils.extend_extrapolate(lsfBltsFreqTableHz, lsfBltsAmplTableCpv, ...
                            tfExtrapolateAmountHz, 'positive', 'exponential', 'exponential');
                        [lsfBltsFreqTableHz, lsfBltsPhaseTableDeg] = bicas.utils.extend_extrapolate(lsfBltsFreqTableHz, lsfBltsPhaseTableDeg, ...
                            tfExtrapolateAmountHz, 'positive', 'exponential', 'linear');
                        
                        
                        % NOTE: INVERTING the tabulated TF.
                        Itf = EJ_library.utils.tabulated_transform(...
                            lsfBltsFreqTableHz * 2*pi, ...
                            1 ./ lsfBltsAmplTableCpv, ...
                            - deg2rad(lsfBltsPhaseTableDeg), ...
                            'extrapolatePositiveFreqZtoZero', 1);
                        
                        % ASSERTION: ITF
                        assert(~Itf.toward_zero_at_high_freq())
                        
                        LfrItfTable{iLsf}{iBltsChannel} = Itf;
                    end
                end
                
            catch Exc1
                Exc2 = MException('BICAS:calib:FailedToReadInterpretRCT', 'Error when interpreting calibration file (RCT) "%s"', filePath);
                Exc2 = Exc2.addCause(Exc1);
                throw(Exc2);
            end
        end
        
        
        
        function tdsCwfFactorsVpc = read_TDS_CWF_RCT(filePath)
            
            Do = dataobj(filePath);
            
            try                
                % NOTE: Undocumented in CDF: zVar CALIBRATION_TABLE is volt/count for just multiplying the TDS signal (for
                % this kind of data). Is not a frequency-dependent transfer function.
                
                % ASSUMPTION: Exactly 1 CDF record.
                % IMPLEMENTATION NOTE: Does not want to rely one dataobj special behaviour for 1 record case
                % ==> Remove leading singleton dimensions, much assertions.
                
                tdsCwfFactorsVpc = shiftdim(Do.data.CALIBRATION_TABLE.data);
                
                % ASSERTIONS: Check CDF array sizes, no change in format.
                assert(iscolumn(tdsCwfFactorsVpc))
                assert(size(    tdsCwfFactorsVpc, 1) == 3)
                
            catch Exc1
                Exc2 = MException('BICAS:calib:FailedToReadInterpretRCT', 'Error when interpreting calibration file (RCT) "%s"', filePath);
                Exc2 = Exc2.addCause(Exc1);
                throw(Exc2);
            end
        end
        
        
        
        function TdsRswfItfList = read_TDS_RSWF_RCT(filePath)
            
            Do = dataobj(filePath);
            
            try
                % ASSUMPTION: Exactly 1 CDF record.
                % IMPLEMENTATION NOTE: Does not want to rely one dataobj special behaviour for 1 record case
                % ==> Remove leading singleton dimensions, much assertions.
                freqsHz  = shiftdim(Do.data.CALIBRATION_FREQUENCY.data);
                amplVpc  = shiftdim(Do.data.CALIBRATION_AMPLITUDE.data);
                phaseDeg = shiftdim(Do.data.CALIBRATION_PHASE.data);
                
                % ASSERTIONS: Check CDF array sizes, no change in format.
                assert(iscolumn(freqsHz));                
                assert(ndims(amplVpc)     == 2)
                assert(ndims(phaseDeg)    == 2)
                assert(size( amplVpc,  1) == 3)
                assert(size( phaseDeg, 1) == 3)
                assert(size( amplVpc,  2) >= bicas.RCT.TF_TABLE_MIN_LENGTH)
                assert(size( phaseDeg, 2) >= bicas.RCT.TF_TABLE_MIN_LENGTH)
                
                EJ_library.utils.assert.all_equal([...
                    length(freqsHz), ...
                    size(amplVpc,  2), ...
                    size(phaseDeg, 2) ]);
                
                for iBltsChannel = 1:3
                    Itf = EJ_library.utils.tabulated_transform(...
                        freqsHz * 2*pi, ...
                        amplVpc(         iBltsChannel, :), ...
                        deg2rad(phaseDeg(iBltsChannel, :)), ...
                        'extrapolatePositiveFreqZtoZero', 1);
                    
                    % ASSERTION: INVERTED TF
                    assert(~Itf.toward_zero_at_high_freq(), ...
                        ['TDS RSWF transfer function appears to go toward zero at high frequencies. Has it not been', ...
                        ' inverted/backward in time, i.e. is it not physical output-to-input?'])
                    
                    TdsRswfItfList{iBltsChannel} = Itf;
                end
                
            catch Exc1
                Exc2 = MException('BICAS:calib:FailedToReadInterpretRCT', 'Error when interpreting calibration file (RCT) "%s"', filePath);
                Exc2 = Exc2.addCause(Exc1);
                throw(Exc2);
            end
        end
        
        
        
    end    %methods(Static, Access=public)
    
    
    
    methods(Static, Access=private)



        % Utility function
        %
        % Function for normalizing the indices of dataobj zVariables.
        % dataobj zVariable arrays have different meanings for their indices depending on whether there are one record
        % or many. If there is one record, then there is not record index. If there are multiple records, then the first
        % index represents the record number. This function inserts a size-one index as the first index.
        % 
        % DO   = dataobj(...)
        % data = Do.data.TRANSFER_FUNCTION_COEFFS.data
        %
        % NOTE: Not well tested on different types of zvar array sizes.
        % 
        function data = norm_do_zv(DataobjZVar)
            % PROPOSAL: Move to utils.
            % PROPOSAL: Shorter name:
            %   norm_dataobj_zvar
            %   norm_do_zv_data
            %   norm_do_zv
            
            data = DataobjZVar.data;            
            
            if DataobjZVar.nrec == 1
                %nDims = ndims(data);
                %order = [nDims + 1, 1:nDims];
                %data = permute(data, order);
                data = shiftdim(data, -1);
            end
        end



        % Utility function to simplify read_BIAS_RCT. Arguments correspond to zVariables in BIAS RCT.
        %
        %
        % ARGUMENTS
        % =========
        % ftfNumCoeffs, ftfDenomCoeffs : 2D matrix of numerator/denominator coefficients for a sequence of FTFs.
        % ItfArray                     : Cell array of ITF (rational_func_transform).
        % 
        %
        % NOTE: Arguments describe FTFs. Return value describes ITFs.
        %
        function ItfArray = create_ITF_sequence(ftfNumCoeffs, ftfDenomCoeffs)
            assert(size(ftfNumCoeffs, 1) == size(ftfDenomCoeffs, 1))
            ItfArray = {};
            
            for i = 1:size(ftfNumCoeffs, 1)
                
                % IMPORTANT NOTE: Invert TF: FTF --> ITF
                Itf = EJ_library.utils.rational_func_transform(...
                    ftfDenomCoeffs(i,:), ...
                    ftfNumCoeffs(i,:));
                
                % ASSERTIONS
                assert(Itf.has_real_impulse_response())
                % Assert ITF. Can not set proper error message.
                assert(~Itf.zero_in_high_freq_limit(), 'Transfer function is not inverted, i.e. not physical output-to-input.')
                
                ItfArray{end+1} = Itf;
            end
        end

        

    end    %methods(Static, Access=public)

end
