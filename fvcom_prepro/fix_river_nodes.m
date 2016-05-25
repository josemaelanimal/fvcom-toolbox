function Mobj = fix_river_nodes(Mobj, max_discharge, dist_thresh, varargin)
% Takes the automatically identified river node positions generated by
% get_EHYPE_rivers or get_FVCOM_rivers and splits or removes them based on
% thresholds of discharge for the former and distance from the open
% boundary join with the coastline.
%
% Mobj = fix_river_nodes(Mobj)
%
% DESCRIPTION:
%   The automatic identifcation of model nodes at which river inputs are
%   discharged sometimes leads to problems with model stability.
%   Specifically:
%       1. Nodes very close to the open boundary join with the coastline
%       can also cause high velocities to occur which if you have bounds
%       checking enabled, will stop the model.
%       2. Very large discharges into relatively small elements (e.g. the
%       Rhine discharge) cause the model to crash.
%       3. Rivers discharging into shallow elements can lead to
%       instabilities.
%
%   This function checks that:
%       1. Rivers are deleted if their distance from the open boundary join
%       with the coastline is less than the specified threshold.
%       2. Any rivers with discharges above the specified threshold are
%       split over a number of nodes such that each node has a maximum
%       discharge less than the treshold.
%       3. Optionally, each river is optimised to use the deepest node
%       within ths distance threshold specified.
%   This order is relatively important otherwise the splitting could put
%   nodes within the land/open boundary joint radius and reduce the river
%   discharge for a given river by eliminating only some of the river
%   nodes.
%
% INPUT:
%   Mobj - struct generated by get_EHYPE_rivers or get_FVCOM_rivers with
%   the following fields:
%       nVerts - number of nodes in the model domain
%       nObs - number of open boundaries
%       lon, lat - nodal positions in spherical coordinates
%       tri - unstructured grid triangulation table
%       read_obc_nodes - open boundary node IDs
%       nRivers - number of rivers in the model domain
%       river_nodes - currently identified river nodes
%       river_names - currently identified river names
%       river_flux - river discharge time series
%   max_discharge - river discharge threshold above which rivers will be
%       split over several nodes (in m^{3}s^{-1}).
%   dist_thresh - distance from the open boundary nodes which connect with
%       land within which nodes will be removed from the river data arrays.
%
%   The following optional keyword-argument pairs are also supported:
%   'depth_optimise' - set to true to search for the deepest node to use
%       for the river within the distance threshold (dist_thresh)
%       specified. This increases the stability of FVCOM. Defaults to
%       false.
%   'debug' - set to true to plot adjusted river nodes from the depth
%       optimisation procedure. Defaults to false.
%
% OUTPUT:
%   Mobj - struct with adjusted river_* fields listed above.
%
% TODO:
%   - Check we don't split a river node into nodes which fall within the
%   distance threshold for the land/open boundary joint.
%
% Author(s)
%   Pierre Cazenave (Plymouth Marine Laboratory)
%
% Revision history:
%   2013-12-13 First version based on the EHYPE section of my
%   create_files_monthly.m script.
%   2014-01-30 Fix a bug revealed when running this script on a larger
%   model domain whereby the splitting of discharges across multiple
%   nodes when a threshold discharge is exceeded didn't work if more than
%   one river exceeded that threshold. Also add better exclusion of
%   candidate river nodes (those with two land boundaries only are now
%   excluded, as well as open ocean nodes and existing river nodes).
%   2015-09-24 Add check for whether we actually have any rivers to
%   process.
%   2016-05-03 Update the number of rivers after fixing river nodes.
%   2016-05-10 Add new option to pick the deepest node within the given
%   radius. This is done after the splitting of river nodes but before the
%   checks for a river input at a node connected to two land boundaries.
%   This is because a river at a node with two land boundaries is always
%   catastrophic, whereas a shallow node is sometimes catastrophic. This
%   approach should also mean we minimise the risk of putting a node back
%   onto a shallower node.
%   2016-05-13 Move the removal of invalid coastline nodes into the
%   function to read coastline nodes rather than having it in the splitting
%   function.
%
%==========================================================================

[~, subname] = fileparts(mfilename('fullpath'));

global ftbverbose
if ftbverbose
    fprintf('\nbegin : %s\n', subname)
end

depth_optimise = false;
debug = false;
for aa = 1:2:length(varargin)
    switch varargin{aa}
        case 'depth_optimise'
            depth_optimise = varargin{aa + 1};
        case 'debug'
            debug = varargin{aa + 1};
    end
end

% Check we actually have some rivers to process.
if Mobj.nRivers < 1
    warning('No rivers specified in the domain.')

    if ftbverbose
        fprintf('end   : %s\n', subname)
    end
    return
end

% Generate names for the variables we're going to use. These may not all be
% used if you are not running ERSEM, but we build them in case.
evars = {'flux', 'temp', 'salt', 'nh4', 'no3', 'o', 'p', 'sio3', 'dic', 'bioalk'};
enames = cell(length(evars));
fnames = cell(length(evars));
for e = 1:length(evars)
    enames{e} = sprintf('river_%s', evars{e});
    fnames{e} = sprintf('fv_%s', evars{e});
end

% Find the model coastline.
coast_nodes = get_coastline(Mobj);

% Remove river nodes close to the open boundaries.
Mobj = clear_boundary_nodes(Mobj, dist_thresh, enames);

% Split big rivers over adjacent nodes.
Mobj = split_big_rivers(Mobj, max_discharge, coast_nodes, enames, fnames);

% If we've been asked to optimise the depth of nodes, do that now. We may
% have to rerun some of the checks above. I don't know yet.
if depth_optimise
    Mobj = optimise_depth(Mobj, dist_thresh, coast_nodes, debug);
end

% Update the number of rivers we have.
Mobj.nRivers = length(Mobj.river_nodes);

if ftbverbose
    fprintf('end   : %s\n', subname)
end

function coast_nodes_valid = get_coastline(Mobj)
% Find the appropriate nodes from the coastline nodes. This is mostly
% lifted from get_EHYPE_rivers.m.
[~, ~, ~, bnd] = connectivity([Mobj.lon, Mobj.lat], Mobj.tri);
boundary_nodes = 1:Mobj.nVerts;
boundary_nodes = boundary_nodes(bnd);
coast_nodes = boundary_nodes(~ismember(boundary_nodes, ...
    [Mobj.read_obc_nodes{:}]));

% Remove invalid coastline nodes (from the perspective of rivers). Those
% are which are connected to two land nodes. I can't think of an elegant
% way of doing this, so brute force it is. This is a bit slow (~10 seconds)
% on my grid with ~13000 coastal nodes.
nogood = nan(size(coast_nodes)); % clear out the nans later.
for nn = 1:length(coast_nodes)
    [row, ~] = find(Mobj.tri == coast_nodes(nn));
    if length(row) == 1
        nogood(nn) = coast_nodes(nn);
    end
end
nogood = nogood(~isnan(nogood));
coast_nodes_valid = setdiff(coast_nodes, nogood);


function Mobj = clear_boundary_nodes(Mobj, dist_thresh, enames)
% Remove nodes close to the open boundary joint with the coastline.
% Identifying the coastline/open boundary joining nodes is simply a case of
% taking the first and last node ID for each open boundary. Using that
% position, we can find any river nodes which fall within that distance and
% simply remove their data from the relevant Mobj.river_* arrays.

global ftbverbose

obc_land_nodes = nan(Mobj.nObs, 2);
for n = 1:Mobj.nObs
    obc_land_nodes(n, :) = [Mobj.read_obc_nodes{n}(1), ...
        Mobj.read_obc_nodes{n}(end)];
    for d = 1:2
        [dist, idx] = sort(sqrt(...
            (Mobj.lon(obc_land_nodes(n, d)) - Mobj.lon(Mobj.river_nodes)).^2 + ...
            (Mobj.lat(obc_land_nodes(n, d)) - Mobj.lat(Mobj.river_nodes)).^2 ...
            ));
        if min(dist) < dist_thresh
            % Delete the positions with indices less than the threshold.
            % This could be more than one river node.
            inds = find(dist < dist_thresh);
            if ftbverbose
                % Have to loop through the indices because fprint'ing a
                % cell array (the river names) is tough...
                for i = 1:length(inds)
                    fprintf('Remove river %s at %.2f, %.2f\n', ...
                        Mobj.river_names{idx(inds(i))}, ...
                        Mobj.lon(Mobj.river_nodes(idx(inds(i)))), ...
                        Mobj.lat(Mobj.river_nodes(idx(inds(i)))))
                end
            end
            Mobj.river_nodes(idx(inds)) = [];
            Mobj.river_flux(:, idx(inds)) = [];
            Mobj.river_names(idx(inds)) = [];
            % Also trim the temperature, salinity and ERSEM variables,
            % if we have them.
            for e = 1:length(enames)
                if isfield(Mobj, enames{e})
                    Mobj.(enames{e})(:, idx(inds)) = [];
                end
            end
        end
    end
end

function Mobj = split_big_rivers(Mobj, max_discharge, coast_nodes, enames, fnames)
% For some of the rivers, the discharge is very large and is the source of
% model instability (e.g. the Rhine crashes my irish_sea_v20 grid). So,
% identify discharges in excess of some value and split that discharge over
% adjacent elements, making sure they're still valid nodes and not used for
% another river. Do this second so we don't have to worry about removing
% nodes based on their distance from the land/open boundary joint which
% have been split, which is the case if these two steps are reversed.

global ftbverbose

riv_idx = 1:size(Mobj.river_flux, 2);
riv_idx = riv_idx(max(Mobj.river_flux) > max_discharge);

if ftbverbose
    fprintf('%i river(s) exceed the specified discharge threshold (%.2f m^{3}s^{-1}).\n', length(riv_idx), max_discharge)
end

for r = riv_idx
    % Based on the flux data, find adjacent nodes over which to split the
    % data and then split all variables (both physics and, optionally,
    % ERSEM data).

    % Eliminate any existing river nodes from the list of candidates.
    candidates = setdiff(coast_nodes, Mobj.river_nodes);

    % Extract the river data for the rivers in excess of the threshold so
    % we can remove them from the existing arrays.
    for e = 1:length(enames)
        if isfield(Mobj, enames{e})
            tmp_struct.(enames{e}) = Mobj.(enames{e})(:, r);
        end
    end

    % Save the nodes and names of this river.
    river_node = Mobj.river_nodes(r);
    river_names = Mobj.river_names(r);

    % Replace the current time series with NaNs. We'll remove them after
    % we've split the rivers in riv_idx. If we remove them here, then the
    % indices in riv_idx get offset by some amount (1 position each time).
    % Doing that is hard to track, so we'll replace with NaNs and remove
    % afterwards.
    for e = 1:length(enames)
        if isfield(Mobj, enames{e})
            Mobj.(enames{e})(:, r) = nan;
        end
    end
    Mobj.river_nodes(r) = nan;
    Mobj.river_names{r} = 'REMOVEME';

    % Split the discharge based on the number of times the specified
    % maximum fits into the actual maximum. So, if the maximum is 10000
    % m^{3}s^{-1} and max_discharge is 2000 m^{3}s^{-1}, then you split
    % over 5 nodes.
    nsplit = ceil(max(tmp_struct.river_flux) / max_discharge);

    % Scale the data by nsplit.
    for e = 1:length(enames)
        if isfield(Mobj, enames{e})
            tmp_struct.(enames{e}) = tmp_struct.(enames{e}) / nsplit;
        end
    end

    % We can keep the original node, but we need to find the
    % remaining nsplit-1 nodes.
    fv_obc = river_node;
    fv_names = {sprintf('%s_%i', river_names{1}, 1)};
    for e = 1:length(fnames)
        if isfield(Mobj, enames{e})
            tmp_struct.(fnames{e}) = repmat(tmp_struct.(enames{e}), [1, nsplit]);
        end
    end

    for ff = 2:nsplit
        % Update the list of candidates to exclude those we've just found.
        candidates = setdiff(candidates, fv_obc);

        [~, idx] = min(sqrt( ...
            (Mobj.lon(river_node) - Mobj.lon(candidates)).^2 + ...
            (Mobj.lat(river_node) - Mobj.lat(candidates)).^2));

        % Now we can check if this node is an FVCOM-compatible one
        % (element of which it's a part has no more than one land
        % boundary).
        [row, ~] = find(Mobj.tri == candidates(idx));

        if length(row) == 1
            % This is a bad node because it is a part of only one element.
            % The rivers need two adjacent elements to work reliably (?).
            % So, we need to repeat the process above until we find a node
            % that's connected to two elements. We'll try the other nodes
            % in the current element before searching the rest of the
            % coastline (which is computationally expensive).

            % Remove the current node index from the list of candidates
            % (i.e. leave only the two other nodes in the element).
            mask = Mobj.tri(row, :) ~= candidates(idx);
            n_tri = Mobj.tri(row, mask);

            % Remove values which aren't coastline values (we don't want to
            % set the river node to an open water node).
            n_tri = intersect(n_tri, candidates);

            % Of the remaining nodes in the element, find the closest one
            % to the original river location.
            [~, n_idx] = sort(sqrt( ...
                (Mobj.rivers.positions(r, 1) - Mobj.lon(n_tri)).^2 ...
                + (Mobj.rivers.positions(r, 2) - Mobj.lon(n_tri)).^2));

            [row_2, ~] = find(Mobj.tri == n_tri(n_idx(1)));
            if length(n_idx) > 1
                [row_3, ~] = find(Mobj.tri == n_tri(n_idx(2)));
            end
            % Closest first
            if length(row_2) > 1
                idx = find(candidates == n_tri(n_idx(1)));
                % The other one (only if we have more than one node to
                % consider).
            elseif length(n_idx) > 1 && length(row_3) > 1
                idx = find(candidates == n_tri(n_idx(2)));
                % OK, we need to search across all the other coastline
                % nodes.
            else
                % TODO: Implement a search of all the other coastline
                % nodes. My testing indicates that we never get here (at
                % least for the grids I've tested). I'd be interested to
                % see the mesh which does get here...
                continue
            end
            fprintf('alternate node ')
        end

        % Update the node ID list and the river names list. The flux we've
        % already done because we know it's just river_flux/nsplit in
        % nsplit columns.
        fv_obc(ff) = candidates(idx);
        fv_names{ff} = sprintf('%s_%i', river_names{1}, ff);
    end

    if ftbverbose
        fprintf('Split river %s over %i nodes.\n', river_names{1}, nsplit)
    end

    % Now we can append these new rivers to the existing list of
    % discharges, nodes and names.
    for e = 1:length(enames)
        if isfield(Mobj, enames{e})
            Mobj.(enames{e}) = [Mobj.(enames{e}), tmp_struct.(fnames{e})];
        end
    end
    Mobj.river_names = [Mobj.river_names; fv_names'];
    Mobj.river_nodes = [Mobj.river_nodes, fv_obc];
end

% Remove all the original river data for the split rivers. Check we're
% doing the right columns by checking if the first row of the fluxes are
% all NaNs for the riv_idx indices.
if all(isnan(Mobj.river_flux(1, riv_idx)))
    for e = 1:length(enames)
        if isfield(Mobj, enames{e})
            Mobj.(enames{e})(:, riv_idx) = [];
        end
    end
    Mobj.river_nodes(riv_idx) = [];
    Mobj.river_names(riv_idx) = [];
end

function Mobj = optimise_depth(Mobj, dist_thresh, coast_nodes, debug)
% For each river node, search within the distance threshold given and pick
% the deepest coastline node for that river.

global ftbverbose

coast_depth = Mobj.h(coast_nodes);
coast_lon = Mobj.lon(coast_nodes);
coast_lat = Mobj.lat(coast_nodes);

for r = 1:length(Mobj.river_nodes)

    % The current river index in the global arrays.
    ri = Mobj.river_nodes(r);

    % Find the nearest nodes.
    [distance, candidates] = sort(sqrt((coast_lon - Mobj.lon(ri)).^2 + ...
        (coast_lat - Mobj.lat(ri)).^2));
    candidate_nodes = candidates(distance < dist_thresh);
    % Find the deepest node within the search radius.
    [deepest_depth, deepest_index] = max(coast_depth(candidates(distance < dist_thresh)));
    % Update if we've deepened this node.
    if ri ~= candidate_nodes(deepest_index)
        % Only update if we improve matters (deepen a river input node).
        if deepest_depth > Mobj.h(ri)
            % Let everyone know what's going on.
            if ftbverbose
                fprintf(['Moving river %s to a node with depth %.2f', ...
                    ' from one with a depth of %.2f (%.2fm deeper).\n'], ...
                    Mobj.river_names{r}, ...
                    Mobj.h(Mobj.river_nodes(r)), ...
                    Mobj.h(coast_nodes(candidate_nodes(deepest_index))), ...
                    Mobj.h(coast_nodes(candidate_nodes(deepest_index))) - Mobj.h(ri))
            end

            % Update the mesh object.
            Mobj.river_nodes(r) = coast_nodes(candidate_nodes(deepest_index));

            if debug
                figure(1)
                clf
                triplot(Mobj.tri, Mobj.lon, Mobj.lat, 'k')
                hold on
                plot(coast_lon, coast_lat, 'r.')
                scatter(coast_lon(candidates(distance < dist_thresh)), ...
                    coast_lat(candidates(distance < dist_thresh)), ...
                    30, ...
                    -coast_depth(candidates(distance < dist_thresh)), ...
                    'filled')
                colorbar
                plot(Mobj.lon(ri), Mobj.lat(ri), 'r^', 'MarkerSize', 20)
                plot(coast_lon(candidate_nodes(deepest_index)), ...
                    coast_lat(candidate_nodes(deepest_index)), ...
                    'b^', ...
                    'MarkerSize', 20)
                axis('tight', 'equal')
                legend('grid', 'coastline', 'depths', 'original', 'new')
                legend('BoxOff')
                xlim([Mobj.lon(ri) - dist_thresh * 2, Mobj.lon(ri) + dist_thresh * 2])
                ylim([Mobj.lat(ri) - dist_thresh * 2, Mobj.lat(ri) + dist_thresh * 2])
                fprintf('Press any key to continue... \n')
                pause
            end
        else
            continue
        end
    end
end
if ftbverbose
    fprintf('Minimum river depth is: %.2f\n', min(Mobj.h(Mobj.river_nodes)))
end
