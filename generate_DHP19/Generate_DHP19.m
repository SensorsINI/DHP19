%--------------------------------------------------------------------------
% Use this script to generate the accumulated frames of DHP19 dataset.
% The script loops over all the DVS recordings and generates .h5 files
% of constant count frames.
% Currently, only constant count frame generation is implemented/tested.
%
% To import the aedat files here we use a modified version of 
% ImportAedatDataVersion1or2, to account for the camera index originating 
% each event.
%--------------------------------------------------------------------------

% Set the paths of code repository folder, data folder and output folder 
% where to generate files of accumulated events.
rootCodeFolder = ''; % root directory of the git repo.
rootDataFolder = ''; % root directory of the data downloaded from resiliosync.
outDatasetFolder = '';

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Cameras number and resolution. Constant for DHP19.
nbcam = 4;
sx = 346;
sy = 260;

%%%%%%%%%%% PARAMETERS: %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Average num of events per camera, for constant count frames.
eventsPerFrame = 7500; 

% Flag and sizes for subsampling the original DVS resolution.
% If no subsample, keep (sx,sy) original img size.
do_subsampling = false;
reshapex = sx;
reshapey = sy;

% Flag to save accumulated recordings.
saveHDF5 = true;

% Flag to convert labels
convert_labels = true;

save_log_special_events = false;
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Hot pixels threshold (pixels spiking above threshold are filtered out).
thrEventHotPixel = 1*10^4;

% Background filter: events with less than dt (us) to neighbors pass through.
dt = 70000;

%%% Masks for IR light in the DVS frames.
% Mask 1
xmin_mask1 = 780;
xmax_mask1 = 810;
ymin_mask1 = 115;
ymax_mask1 = 145;
% Mask 2
xmin_mask2 = 346*3 + 214;
xmax_mask2 = 346*3 + 221;
ymin_mask2 = 136;
ymax_mask2 = 144;

%%% Paths     %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
t = datetime('now','Format','yyyy_MM_dd''_''HHmmss');
%
DVSrecFolder = fullfile(rootDataFolder,'DVS_movies/');
viconFolder = fullfile(rootDataFolder,'Vicon_data/');

% output directory where to save files after events accumulation.
out_folder_append = ['h5_dataset_',num2str(eventsPerFrame),'_events'];

addpath(fullfile(rootCodeFolder, 'read_aedat/'));
addpath(fullfile(rootCodeFolder, 'generate_DHP19/'));

% Setup output folder path, according to accumulation type and spatial resolution.
outputFolder = fullfile(outDatasetFolder, out_folder_append,[num2str(reshapex),'x',num2str(reshapey)]);

log_path = fullfile(outDatasetFolder, out_folder_append);
log_file = sprintf('%s/log_generation_%sx%s_%s.log',log_path,num2str(reshapex),num2str(reshapey), t);

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

numConvertedFiles = 0;

% setup output folder
if ~exist(outputFolder,'dir'), mkdir(outputFolder); end
cd(outputFolder)

% log files
fileID = fopen(sprintf('%s/Fileslog_%s.log', log_path, t), 'w');

if save_log_special_events
    fileID_specials = fopen(sprintf('%s/SpecialEventsLog_%s.log', log_path, t), 'w');
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Loop over the subjects/sessions/movements.

numSubjects = 17;
numSessions = 5;

fileIdx = 0;

for subj = 1:numSubjects 
    subj_string = sprintf('S%d',subj);
    sessionsPath = fullfile(DVSrecFolder, subj_string);
    
    for sess = 1:numSessions
        sessString = sprintf('session%d',sess);

        movementsPath = fullfile(sessionsPath, sessString);
        
        if     sess == 1, numMovements = 8;
        elseif sess == 2, numMovements = 6;
        elseif sess == 3, numMovements = 6;
        elseif sess == 4, numMovements = 6;
        elseif sess == 5, numMovements = 7;
        end
        
        for mov = 1:numMovements
            fileIdx = fileIdx+1;
            
            movString = sprintf('mov%d',mov);

            aedatPath = fullfile(movementsPath, strcat(movString, '.aedat'));
            
            % skip iteration if recording is missing.
            if not(isfile(aedatPath)==1)
                continue
            end
            
            disp([num2str(fileIdx) ' ' aedatPath]);
            
            labelPath = fullfile(viconFolder, strcat(subj_string,'_',num2str(sess),'_',num2str(mov), '.mat'));
            assert(isfile(labelPath)==1);

            % name of .h5 output file
            outDVSfile = strcat(subj_string,'_',sessString,'_',movString,'_',num2str(eventsPerFrame),'events');
            
            out_file = fullfile(outputFolder, outDVSfile);            
            
            
            % extract and accumulate if the output file is not already 
            % generated and if the input aedat file exists.
            if (not(exist(strcat(out_file,'.h5'), 'file') == 2)) && (exist(aedatPath, 'file') == 2)
                
                aedat = ImportAedat([movementsPath '/'], strcat(movString, '.aedat'));
                XYZPOS = load(labelPath);
                
                events = int64(aedat.data.polarity.timeStamp);
                
                %%% conditions on special events %%%
                try
                    specialEvents = int64(aedat.data.special.timeStamp);
                    numSpecialEvents = length(specialEvents);
                    
                    if save_log_special_events
                        % put the specialEvents to string, to print to file.
                        specials_='';
                        for k = 1:numel(specialEvents)
                            specials_ = [specials_ ' ' num2str(specialEvents(k))];
                        end
                        fprintf(fileID_specials, '%s \t %s\n', aedatPath, specials_); 
                    end % log_special_events
                    
                    %%% Special events cases: %%%%%%%%%%%%%%%%%%%%%%%%%%%%%
                    %
                    % a) 1 without special event field (S14/session5/mov3)
                    %
                    % b) 2 with just 1 special event:
                    %    S5/session4/mov2: 
                    %                     special     1075788910
                    %                     min(events) 1055513693
                    %                     max(events) 1076195668 
                    %    S16/session2/mov4:
                    %                     special     278928206
                    %                     min(events) 258344886
                    %                     max(events) 279444627
                    %    in both cases, special is closer to the end of the
                    %    recording, hence we assume the initial special is
                    %    missing.
                    %
                    % c) 326 with 2 special events: these are all 2
                    %    consecutive events (or two at the same timestamp).
                    %
                    % d) 225 with 3 special events: first two are
                    %    consecutive, the 3rd is the stop special event.
                    %
                    % e) 2 with 4 special events: 
                    %    first 3 are equal, 4th is 1 timestep after the first.
                    %    Same as c)
                    %    S4/session5/mov7: 
                    %                     special     149892732(x3), 149892733
                    %                     min(events) 146087513
                    %                     max(events) 170713237
                    %    S12/session5/mov4:
                    %                     special     411324494(x3), 411324495
                    %                     min(events) 408458645
                    %                     max(events) 429666644
                    %    in both cases the special events are closer to the
                    %    start of the recording, hence we assume the final 
                    %    special is missing.
                    % 
                    % f) 3 with 5 special events: first 3 (or 4) are equal, 
                    %    1 (or 0) right after the first, the last event is the final
                    %    Same as d)
                    %    (S5/session1/mov4, S5/session2/mov4, S5/session3/mov3).
                    %
                    % g) 2 with >700 special events (S4/session3/mov4, S4/session3/mov6)
                    %    -> these recordings are corrupted, removed from DHP19
                    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
                    
                    % use head joint to calculate total number of timesteps
                    % when information is missing from special events.
                    % 1e4 factor is to go from 100Hz Vicon sampling freq to 
                    % us DVS temporal resolution.
                    n = length(XYZPOS.XYZPOS.head)*10000;

                    if numSpecialEvents == 0
                        % the field aedat.data.special does not exist
                        % for S14_5_3. There are no other cases.
                        error('special field is there but is empty');
                        
                    elseif numSpecialEvents == 1
                        
                        if (specialEvents-min(events)) > (max(events)-specialEvents)
                            % The only event is closer to the end of the recording.
                            stopTime = specialEvents;
                            startTime = floor(stopTime - n);
                        else
                            startTime = specialEvents;
                            stopTime = floor(startTime + n);
                        end
                        
                        
                    elseif (numSpecialEvents == 2) || (numSpecialEvents == 4)
                        % just get the minimum value, the others are max 1
                        % timestep far from it.
                        special = specialEvents(1); %min(specialEvents);
                        
                        %%% special case, for S14_1_1 %%%
                        % if timeStamp overflows, then get events only
                        % until the overflow.
                        if events(end) < events(1)
                            startTime = special;
                            stopTime = max(events);
                        
                        
                        %%% regular case %%%
                        else
                            if (special-events(1)) > (events(end)-special)
                                % The only event is closer to the end of the recording.
                                stopTime = special;
                                startTime = floor(stopTime - n);
                            else
                                startTime = special;
                                stopTime = floor(startTime + n);
                            end
                        end 
                        
                    elseif (numSpecialEvents == 3) || (numSpecialEvents == 5)
                        % in this case we have at least 2 distant special
                        % events that we consider as start and stop.
                        startTime = specialEvents(1);
                        stopTime = specialEvents(end);
                        
                    elseif numSpecialEvents > 5
                        % Two recordings with large number of special events.
                        % Corrupted recordings, skipped.
                        continue 
                    end
                  
                catch 
                    % if no special field exists, get first/last regular
                    % events (not tested).
                    startTime = events(1); 
                    stopTime = events(end); 
                    
                    if save_log_special_events
                        disp(strcat("** Field 'special' does not exist: ", aedatPath));
                        fprintf(fileID_specials, '%s \t\n', aedatPath);
                    end %
                end % end try reading special events
                
                disp(strcat('Processing file: ',outDVSfile));
                disp(strcat('Tot num of events in all cameras: ', num2str(eventsPerFrame*nbcam)));
                
                ExtractEventsToFramesAndMeanLabels( ...
                        fileID, ...
                        aedat, ...
                        events, ...
                        eventsPerFrame*nbcam, ...
                        startTime, ...
                        stopTime, ...
                        out_file, ...
                        XYZPOS, ...
                        sx, ...
                        sy, ...
                        nbcam, ...
                        thrEventHotPixel, ...
                        dt, ...
                        xmin_mask1, xmax_mask1, ymin_mask1, ymax_mask1, ...
                        xmin_mask2, xmax_mask2, ymin_mask2, ymax_mask2, ...
                        do_subsampling, ...
                        reshapex, ...
                        reshapey, ...
                        saveHDF5, ...
                        convert_labels)
            else
                fprintf('%d, File already esists: %s\n', numConvertedFiles, out_file); 
                numConvertedFiles = numConvertedFiles +1; 
                 
            end % if file not exist yet condition
        end % loop over movements
    end % loop over sessions
end % loop over subjects

fclose(fileID);

if save_log_special_events
    fclose(fileID_specials);
end
