function Mobj = fix_river_nodes(Mobj, max_discharge, dist_thresh)
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
%
%   This function checks that:
%       1. Rivers are deleted if their distance from the open boundary join
%       with the coastline is less than the specified threshold.
%       2. Any rivers with discharges above the specified threshold are
%       split over a number of nodes such that each node has a maximum
%       discharge less than the treshold.
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
%
%==========================================================================

subname = 'fix_river_nodes';

global ftbverbose
if ftbverbose
    fprintf('\nbegin : %s\n', subname)
end

% Check we actually have some rivers to process.
if Mobj.nRivers < 1
    warning('No rivers specified in the domain.')

    if ftbverbose
        fprintf('end   : %s\n', subname)
    end
    return
end

% Remove nodes close to the open boundary joint with the coastline.
% Identifying the coastline/open boundary joining nodes is simply a case of
% taking the first and last node ID for each open boundary. Using that
% position, we can find any river nodes which fall within that distance and
% simply remove their data from the relevant Mobj.river_* arrays.
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
        end
    end
end

clear obc_land_nodes n d dist idx inds

% For some of the rivers, the discharge is very large and is the source of
% model instability (e.g. the Rhine crashes my irish_sea_v20 grid). So,
% identify discharges in excess of some value and split that discharge over
% adjacent elements, making sure they're still valid nodes and not used for
% another river. Do this second so we don't have to worry about removing
% nodes based on their distance from the land/open boundary joint which
% have been split, which is the case if these two steps are reversed.
riv_idx = 1:size(Mobj.river_flux, 2);
riv_idx = riv_idx(max(Mobj.river_flux) > max_discharge);

% Find the appropriate nodes from the coastline nodes. This is mostly
% lifted from get_EHYPE_rivers.m.
[~, ~, ~, bnd] = connectivity([Mobj.lon, Mobj.lat], Mobj.tri);
boundary_nodes = 1:Mobj.nVerts;
boundary_nodes = boundary_nodes(bnd);
coast_nodes = boundary_nodes(~ismember(boundary_nodes, ...
    [Mobj.read_obc_nodes{:}]));
clear boundary_nodes bnd

% Find all the nodes which are connected to two land nodes. These cause
% problems with the search for valid river nodes. I can't think of an
% elegant way of doing this, so brute force it is. This is a bit slow (~10
% seconds) on my grid with ~13000 coastal nodes.
nogood = nan(size(coast_nodes)); % clear out the nans later.
for nn = 1:length(coast_nodes)
    [row, ~] = find(Mobj.tri == coast_nodes(nn));
    if length(row) == 1
        nogood(nn) = coast_nodes(nn);
    end
end
nogood = nogood(~isnan(nogood));
coast_nodes_valid = setdiff(coast_nodes, nogood);
clear nn row nogood

if ftbverbose
    fprintf('%i river(s) exceed the specified discharge threshold (%.2f m^{3}s^{-1}).\n', length(riv_idx), max_discharge)
end

for r = riv_idx

    % Eliminate any existing river nodes from the list of candidates.
    candidates = setdiff(coast_nodes_valid, Mobj.river_nodes);

    % Extract the river data for the rivers in excess of the threshold so
    % we can remove them from the existing arrays.
    river_flux = Mobj.river_flux(:, r);
    river_node = Mobj.river_nodes(r);
    river_names = Mobj.river_names(r);
    % Replace the current time series with NaNs. We'll remove them to
    % after we've split the rivers in riv_idx. If we remove them here, then
    % the indices in riv_idx get offset by some amount (1 position each
    % time). Doing that is hard to track, so we'll replace with NaNs and
    % remove afterwards.
    Mobj.river_flux(:, r) = nan;
    Mobj.river_nodes(r) = nan;
    Mobj.river_names{r} = 'REMOVEME';

    % Split the discharge based on the number of times the specified
    % maximum fits into the actual maximum. So, if the maximum is 10000
    % m^{3}s^{-1} and max_discharge is 2000 m^{3}s^{-1}, then you split
    % over 5 nodes.
    nsplit = ceil(max(river_flux) / max_discharge);

    % Scale the flux by nsplit.
    river_flux = river_flux / nsplit;

    % We can keep the original node, but we need to find the
    % remaining nsplit-1 nodes.
    fv_obc = river_node;
    fv_names = {sprintf('%s_%i', river_names{1}, 1)};
    fv_flow = repmat(river_flux, [1, nsplit]);

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
    Mobj.river_flux = [Mobj.river_flux, fv_flow];
    Mobj.river_names = [Mobj.river_names; fv_names'];
    Mobj.river_nodes = [Mobj.river_nodes, fv_obc];
end

% Remove all the original river fluxes for the split rivers. Check we're
% doing the right columns by checking if the first row of the fluxes are
% all NaNs for the riv_idx indices.
if all(isnan(Mobj.river_flux(1, riv_idx)))
    Mobj.river_flux(:, riv_idx) = [];
    Mobj.river_nodes(riv_idx) = [];
    Mobj.river_names(riv_idx) = [];
end

% Tidy up.
clear r riv_idx river_flux river_nodes river_names nsplit ...
    boundary_nodes coast_nodes candidates fv_flow fv_dist ...
    fv_names fv_obc idx mask n_tri row ff

if ftbverbose
    fprintf('end   : %s\n', subname)
end
