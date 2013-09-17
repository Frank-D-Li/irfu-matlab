function c_ulf_process(tint,cl_id,freqRange)
% C_ULF_PROCESS  process Cluster ULF data
%
%  c_ulf_process(tint,cl_id,freqRange)
%
%  freqRange - 'all' (default), 'pc35', 'pc12'
%
%  Reads CAA data from disk and computes wave spectra and polarization
%  parameters.
%
%  See also IRF_EBSP

% ----------------------------------------------------------------------------
% "THE BEER-WARE LICENSE" (Revision 42):
% <yuri@irfu.se> wrote this file.  As long as you retain this notice you
% can do whatever you want with this stuff. If we meet some day, and you think
% this stuff is worth it, you can buy me a beer in return.   Yuri Khotyaintsev
% ----------------------------------------------------------------------------
%
% This software was developed as part of the MAARBLE (Monitoring,
% Analyzing and Assessing Radiation Belt Energization and Loss)
% collaborative research project which has received funding from the
% European Community's Seventh Framework Programme (FP7-SPACE-2011-1)
% under grant agreement n. 284520.

if nargin < 1
  % These are example test intervals
%freqRange = 'all';cl_id = 1; tint=iso2epoch('2010-10-13T12:00:00Z') + [0 3*3600]; % PC3-5 example
%freqRange = 'pc35';cl_id = 1; tint=iso2epoch('2011-08-30T15:00:00Z') + [0 4*3600]; % PC3-5 example
%freqRange = 'pc35';cl_id = 1; tint=iso2epoch('2011-08-28T09:30:00Z') + [0 3*3600]; % PC3-5 example
%freqRange = 'pc35';cl_id = 4; tint=iso2epoch('2011-08-01T07:00:00Z') + [0 6*3600]; % PC3-5 example
%freqRange = 'pc35';cl_id = 1; tint=iso2epoch('2011-07-16T12:03:00Z') + [0 3*3600]; % PC3-5 example
%freqRange = 'pc12';cl_id = 1;tint=iso2epoch('2007-01-03T16:00:00Z') + [0 0.5*3600]; % PC1-2 example
%freqRange = 'pc12';cl_id = 1;tint=iso2epoch('2011-11-01T20:13:00Z') + [0 25*60]; % PC1-2 example
freqRange = 'pc12';cl_id = 3;tint=iso2epoch('2002-01-15T07:00:00Z') + [0 2*3600]; % PC1-2 example
%freqRange = [10 180]; cl_id = 4;tint=iso2epoch('2001-02-26T05:18:00Z') + [0 60]; % VLF example
elseif nargin < 3
  freqRange = 'all';
end

%outDir = '.';
plotFlag = 1;
exportFlag = 1;

wantPC12 = 0;
wantPC35 = 0; wantSCM = 0;
if ischar(freqRange)
    switch lower(freqRange)
        case 'all'
            wantPC12 = 1;
            wantPC35 = 1;
        case 'pc12'
            wantPC12 = 1;
        case 'pc35'
            wantPC35 = 1;
        otherwise
            error('Invalid value for freqRange')
    end
else
    if freqRange(1) > 1, wantSCM = 1; end
end


% Round time interval to minutes
tint = [floor(tint(1)/60) ceil(tint(2)/60)]*60;
cl_s = int2str(cl_id);
% Extend time interval by these ranges to avoid edge effects 
DT_PC5 = 80*60; DT_PC2 = 120;

%% Download data
if 0
    caa_download(tint+DT_PC5*[-1 1],['C' cl_s '_CP_FGM_5VPS'],'nowildcard');
    caa_download(tint+DT_PC5*[-1 1],['C' cl_s '_CP_EFW_L3_E'],'nowildcard');
    caa_download(tint+DT_PC5*[-1 1],['C' cl_s '_CP_AUX_POSGSE_1M'],'nowildcard');
    caa_download(tint+DT_PC5*[-1 1],'CL_SP_AUX','nowildcard');
    caa_download(tint+DT_PC2*[-1 1],['C' cl_s '_CP_FGM_FULL_ISR2'],'nowildcard');
    caa_download(tint+DT_PC2*[-1 1],['C' cl_s '_CP_EFW_L2_E'],'nowildcard');
    if wantSCM
      caa_download(tint+DT_PC2*[-1 1],['C' cl_s '_CP_STA_CWF_HBR_ISR2'],'nowildcard');
    end
end

%% Load

% Construct 1 min-B0 (lowpassed at 1/600 Hz)
gseB_5VPS = c_caa_var_get(['B_vec_xyz_gse__C' cl_s '_CP_FGM_5VPS'],...
    'mat','tint',tint+DT_PC5*[-1 1]);
gseR = c_caa_var_get(['sc_pos_xyz_gse__C' cl_s '_CP_FGM_5VPS'],...
    'mat','tint',tint+DT_PC5*[-1 1]);
gseV = c_caa_var_get(['sc_v_xyz_gse__C' cl_s '_CP_AUX_POSGSE_1M'],...
    'mat','tint',tint+DT_PC5*[-1 1]);
SAXlat = c_caa_var_get(['sc_at' cl_s '_lat__CL_SP_AUX'],...
    'mat','tint',tint+DT_PC5*[-1 1]);
SAXlong = c_caa_var_get(['sc_at' cl_s '_long__CL_SP_AUX'],...
    'mat','tint',tint+DT_PC5*[-1 1]);
[xspin,yspin,zspin] = sph2cart(mean(SAXlong(:,2))*pi/180,...
    mean(SAXlat(:,2))*pi/180,1); SAX = [xspin yspin zspin];
R = c_coord_trans('gse','isr2',gseR,'SAX',SAX);
V = c_coord_trans('gse','isr2',gseV,'SAX',SAX);
B_5VPS = c_coord_trans('gse','isr2',gseB_5VPS,'SAX',SAX);

MIN_E_QUALITY=2; % disregard E with quality below this
if wantPC35
    E_4SEC = c_caa_var_get(['E_Vec_xy_ISR2__C' cl_s '_CP_EFW_L3_E'],...
        'mat','tint',tint+DT_PC5*[-1 1]);
    E_4SEC_Quality = c_caa_var_get(['E_quality__C' cl_s '_CP_EFW_L3_E'],...
      'mat','tint',tint+DT_PC5*[-1 1]);
    E_4SEC(E_4SEC_Quality(:,2)<MIN_E_QUALITY,2:end) = NaN;
end
if wantPC12
    B_FULL = c_caa_var_get(['B_vec_xyz_isr2__C' cl_s '_CP_FGM_FULL_ISR2'],...
        'mat','tint',tint+DT_PC2*[-1 1]);
    
    E_L2 = c_caa_var_get(['E_Vec_xy_ISR2__C' cl_s '_CP_EFW_L2_E'],...
        'mat','tint',tint+DT_PC2*[-1 1]);
    E_L2_Quality = c_caa_var_get(['E_quality__C' cl_s '_CP_EFW_L2_E'],...
        'mat','tint',tint+DT_PC2*[-1 1]);
    E_L2(E_L2_Quality(:,2)<MIN_E_QUALITY,2:end) = NaN;  
end
if ~wantPC35 && ~wantPC12
    E_L2 = c_caa_var_get(['E_Vec_xy_ISR2__C' cl_s '_CP_EFW_L2_E'],...
        'mat','tint',tint+[-1 1]);
    B_FULL = c_caa_var_get(['B_vec_xyz_isr2__C' cl_s '_CP_FGM_FULL_ISR2'],...
        'mat','tint',tint+[-1 1]);
    if wantSCM
        BSC = c_caa_var_get('B_vec_xyz_Instrument__C4_CP_STA_CWF_HBR_ISR2','mat');
    end
end

%% Calculate and plot
bf = irf_filt(B_5VPS,0,1/600,1/5,5);
t_1min = ((tint(1)-DT_PC5):60:(tint(end)+DT_PC5))';
B0_1MIN = irf_resamp(bf,t_1min); clear bf
facMatrix = irf_convert_fac([],B0_1MIN,R);
if exportFlag
  maarble.export(facMatrix,tint,cl_id)
end

if wantPC35
  t_4SEC = ((tint(1)+2-DT_PC5):4:(tint(end)+DT_PC5))';
  B_4SEC = irf_resamp(B_5VPS,t_4SEC);
  E3D_4SEC = irf_edb(irf_resamp(E_4SEC,t_4SEC),B_4SEC,15,'Eperp+NaN'); % Ez
  
  % Construct the inertial frame
  evxb = irf_tappl(irf_cross(B_4SEC,irf_resamp(V,t_4SEC)),'*1e-3*(-1)');
  iE3D_4SEC = E3D_4SEC;
  iE3D_4SEC(:,2:4) = iE3D_4SEC(:,2:4) - evxb(:,2:4);
  
  ebsp = ...
    irf_ebsp(iE3D_4SEC,B_4SEC,[],B0_1MIN,R,'pc35',...
    'fac','polarization','noresamp','fullB=dB','facMatrix',facMatrix);
  tlim_ebsp();
  if plotFlag
    h = irf_pl_ebsp(ebsp);
    irf_zoom(h,'x',tint)
    title(h(1),['Cluster ' cl_s ', ' irf_disp_iso_range(tint,1)])
    set(gcf,'paperpositionmode','auto')
    print('-dpng',['MAARBLE_ULF_PC35_' irf_fname(tint,5)])
  end
  if exportFlag
    maarble.export(ebsp,tint,cl_id,'pc35')
  end
end

if wantPC12
  fFGM = 22.5;
  t_BASE = (fix(min(B_FULL(1,1),E_L2(1,1))):2.0/fFGM:ceil(max(B_FULL(end,1),E_L2(end,1))))';
  B_BASE = irf_resamp(B_FULL,t_BASE);
  E3D_BASE = irf_edb(irf_resamp(E_L2,t_BASE),B_BASE,15,'Eperp+NaN'); % Ez
  
  % Construct the inertial frame
  evxb = irf_tappl(irf_cross(B_BASE,irf_resamp(V,t_BASE)),'*1e-3*(-1)');
  iE3D_BASE = E3D_BASE;
  iE3D_BASE(:,2:4) = iE3D_BASE(:,2:4) - evxb(:,2:4);
  tic
  ebsp = irf_ebsp(iE3D_BASE,B_BASE,[],B0_1MIN,R,'pc12',...
    'fac','polarization','noresamp','fullB=dB','dedotb=0','nav',12,...
    'facMatrix',facMatrix);
  toc
  tlim_ebsp();
  if plotFlag
    h = irf_pl_ebsp(ebsp);
    irf_zoom(h,'x',tint)
    title(h(1),['Cluster ' cl_s ', ' irf_disp_iso_range(tint,1)])
    set(gcf,'paperpositionmode','auto')
    print('-dpng',['MAARBLE_ULF_PC12_' irf_fname(tint,5)])
  end
  if exportFlag
    maarble.export(ebsp,tint,cl_id,'pc12')
  end
end

if ~wantPC35 && ~wantPC12
  tic
  if wantSCM
    ebsp = irf_ebsp(E_L2,BSC,B_FULL,B_5VPS,R,freqRange,...
      'fac','polarization','dedotb=0');
  else
    ebsp = irf_ebsp(E_L2,B_FULL,[],B_5VPS,R,freqRange,...
      'fac','polarization','dedotb=0','fullB=dB');
  end
  toc
  h = irf_pl_ebsp(ebsp);
    irf_zoom(h,'x',tint)
    title(h(1),['Cluster ' cl_s ', ' irf_disp_iso_range(tint,1)])
end

  function tlim_ebsp % Trim ebsp to tlim
    IGNORE_FIELDS = {'f','flagFac','fullB','B0','r'};
    fieldsEBSP = fields(ebsp);
    tFields = setxor(fieldsEBSP,IGNORE_FIELDS);
    %nData = length(ebsp.t);
    [~,idx] = irf_tlim(ebsp.t,tint);
    for fName = tFields
      s = size(ebsp.(fName{:}));
      switch numel(s)
        case 2
          ebsp.(fName{:}) = ebsp.(fName{:})(idx,:);
        case 3
          ebsp.(fName{:}) = ebsp.(fName{:})(idx,:,:);
        otherwise
          error('wrong size!')
      end
    end
  end
end

