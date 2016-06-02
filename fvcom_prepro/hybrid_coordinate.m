function Mobj = hybrid_coordinate(conf, Mobj)
% Create a hybrid vertical coordinates file.
%
% Mobj = hybrid_coordinate(conf, Mobj);
%
% DESCRIPTION:
%   Calculates and writes a hybird coordinates file for FVCOM.
%
% INPUT:
%   conf - configuration struct with the following fields:
%       sigma_file - file path into which to write the hybrid coordinates
%       H0 - transition depth of the hybrid coordinates
%       DU - upper water boundary thickness (metres)
%       DL - lower water boundary thickness (metres)
%       KU - layer number in the water column of DU
%       KL - layer number in the water column of DL
%       nlev - number of vertical levels (layers + 1)
%   Mobj - Mesh object with the following fields:
%       h - water depth at the nodes
%
% OUTPUT:
%   Mobj - Mesh object with the following new fields:
%       siglev - Sigma levels at the nodes
%       siglevc - Sigma levels at the elements
%       siglay - Sigma layers at the nodes
%       siglayc - Sigma layers at the elements
%       siglevz - Water depth levels at the nodes
%       siglevzc - Water depth levels at the elements
%       siglayz - Water depth layers at the nodes
%       siglayzc - Water depth layers at the elements
%       hc - Water depth at the elements
%
% EXAMPLE USAGE:
%   conf.sigma_file = 'coord_hybrid.sig';
%   conf.nlev = 41;
%   conf.DU = 25;
%   conf.DL = 25;
%   conf.Hmin = 200;
%   conf.KU = 5;
%   conf.KL = 5;
%   conf.ZKU = [.5 .5 .5 .5 .5];
%   conf.ZKL = [.5 .5 .5 .5 .5];
%   conf.H0 = 100;
%   conf.nlev = 20;
%   conf.DU = 25;
%   conf.DL = 25;
%   conf.KU = 5;
%   conf.KL = 5;
%   Mobj.h = random(100, 1) * 100;  % 100 random bathymetry points
%   Mobj = hybrid_coordinate(conf, Mobj);
%
% Author(s):
%   Ricard Torres (Plymouth Marine Laboratory)
%   Pierre Cazenave (Plymouth Marine Laboratory)
%
% Revision history:
%   2015-05-24 First version based on Riqui's initial implementation.
%
%==========================================================================

[~, subname] = fileparts(mfilename('fullpath'));
global ftbverbose
if ftbverbose
    fprintf('\nbegin : %s\n', subname)
end

% Limits on the optimisation run.
optimisation_settings = optimset('MaxFunEvals', 5000, ...
    'MaxIter', 5000, ...
    'TolFun', 10e-5, ...
    'TolX', 1e-7);

% Extract the relevant information from the conf struct.
nlev = conf.nlev;
H0 = conf.H0;
DU = conf.DU;
DL = conf.DL;
KU = conf.KU;
KL = conf.KL;

% Solve for z1-z2 to find Hmin parameter
if ftbverbose
    fprintf('Optimising the hybrid coordinates... ')
end
ZKU = repmat(DU./KU, 1, KU);
ZKL = repmat(DL./KL, 1, KL);
fparams = @(H)hybrid_coordinate_hmin(H, nlev, DU, DL, KU, KL, ZKU, ZKL);
% Does the sigma_gen function do the same thing as hybrid_coordinate_hmin?
% It seems suspiciously similar, except it has separate calculations for
% depths above and below H0 (MIN CONSTANT DEPTH). If hmin == h, then
% sigma_gen does almost the same thing as hybrid_coordinate_hmin (I think -
% I haven't actually tested that assertation).
% fparams = @(H)sigma_gen(nlev, DL, DU, KL, KU, ZKL, ZKU, H, H);
[Hmin, ~] = fminsearch(fparams, H0, optimisation_settings);

if ftbverbose
    fprintf('done.\n')
    fprintf('Saving to %s... ', conf.sigma_file)
end

% Save to the given file name.
fout = fopen(conf.sigma_file, 'wt');
assert(fout >= 0, 'Error opening sigma file: %s', conf.sigma_file)
fprintf(fout, 'NUMBER OF SIGMA LEVELS = %d\n', nlev);
fprintf(fout, 'SIGMA COORDINATE TYPE = GENERALIZED\n');
fprintf(fout, 'DU = %4.1f\n', DU);
fprintf(fout, 'DL = %4.1f\n', DL);
fprintf(fout, 'MIN CONSTANT DEPTH = %10.1f\n', round(Hmin));
fprintf(fout, 'KU = %d\n', KU);
fprintf(fout, 'KL = %d\n', KL);
% Add the thicknesses with a loop.
fprintf(fout, 'ZKU = ');
for ii = 1:length(ZKU)
    fprintf(fout, '%4.1f', ZKU(ii));
end
fprintf(fout, '\n');
fprintf(fout, 'ZKL = ');
for ii = 1:length(ZKU)
    fprintf(fout, '%4.1f', ZKL(ii));
end
fprintf(fout,'\n');
fclose(fout);

if ftbverbose
    fprintf('done.\n')
    fprintf('Populating Mobj... ')
end

% Create the arrays of the layer and level sigma coordinates.
for xx = 1:length(Mobj.h)
    Mobj.siglev(xx,:) = sigma_gen(nlev,DL,DU,KL,KU,ZKL,ZKU,Mobj.h(xx),Hmin);
end
Mobj.siglay = Mobj.siglev(:,1:end-1) + (diff(Mobj.siglev,1,2)/2);
% Turn off ftbverbose for this loop.
old = ftbverbose;
ftbverbose = 0;
for zz = 1:nlev-1
    Mobj.siglevc(:, zz) = nodes2elems(Mobj.siglev(:, zz), Mobj);
    Mobj.siglayc(:, zz) = nodes2elems(Mobj.siglay(:, zz), Mobj);
end
% An extra level compared with layers.
Mobj.siglevc(:, zz + 1) = nodes2elems(Mobj.siglev(:, zz + 1), Mobj);
ftbverbose = old;
clear old

% Create a depth array for the element centres.
if ~isfield(Mobj, 'hc')
    Mobj.hc = nodes2elems(Mobj.h, Mobj);
end

% Finally, make some [depth, sigma] arrays.
Mobj.siglevz = repmat(Mobj.h, 1, nlev) .* Mobj.siglev;
Mobj.siglayz = repmat(Mobj.h, 1, nlev-1) .* Mobj.siglay;
Mobj.siglevzc = repmat(Mobj.hc, 1, nlev) .* Mobj.siglevc;
Mobj.siglayzc = repmat(Mobj.hc, 1, nlev-1) .* Mobj.siglayc;

if ftbverbose
    fprintf('done.\n')
    fprintf('end   : %s\n', subname)
end

return

function ZZ = hybrid_coordinate_hmin(H, nlev, DU, DL, KU, KL, ZKU, ZKL)
% Helper function to find the relevant minimum depth. I think.
%
%   ZZ = hybrid_coordinate_hmin(H, nlev, DU, DL, KU, KL, ZKU, ZKL)
%
% INPUT:
%   H: transition depth of the hybrid coordinates?
%   nlev: number of vertical levels (layers + 1)
%   DU: upper water boundary thickness (metres)
%   DL: lower water boundary thickness (metres)
%   KU: layer number in the water column of DU
%   KL: layer number in the water column of DL
%
% OUTPUT:
%   ZZ: minimum water depth?
% 
% Author(s):
%   Ricard Torres (Plymouth Marine Laboratory)

if DU + DL > 1.25 * H;
    disp('Depth too shallow for the chosen DU and DL values')
    return
end

Z0 = zeros(nlev, 1);
Z2 = Z0;
Z0(1, 1) = 0;
DL2 = 0.001;
DU2 = 0.001;
KBM1 = nlev - 1;
for nn = 1:nlev - 1
    X1 = DL2 + DU2;
    X1 = X1 * (KBM1 - nn) / KBM1;
    X1 = X1 - DL2;
    X1 = tanh(X1);
    X2 = tanh(DL2);
    X3 = X2 + tanh(DU2);
    
    Z0(nn + 1, 1)=((X1 + X2) / X3) - 1;
end

% s-coordinates
X1 = (H - DU - DL);
X2 = X1 ./ H;
DR = X2 ./ (nlev - KU - KL - 1);

Z2(1,1) = 0.0;

for K = 2:KU + 1
    Z2(K, 1) = Z2(K - 1, 1) - (ZKU(K - 1) ./ H);
end

for K= KU + 2:nlev - KL
    Z2(K, 1) = Z2(K - 1, 1) - DR;
end

KK = 0;
for K = nlev - KL + 1:nlev
    KK = KK + 1;
    Z2(K, 1) = Z2(K - 1, 1) - (ZKL(KK) ./ H);
end
ZZ = abs(median(diff(Z0) - diff(Z2)));

return

function debug_mode()
% Test with made up data. This isn't actually used at all, but it's handy
% to leave around for debugging things.
% Hmax = 200;
y = 0:100;
B = 100;
H = Hmax .* exp(-((y./B-0.15).^2 ./(0.5).^2));
% H = 120;
Z0 = zeros(length(H), nlev);
Z2 = zeros(length(H), nlev);
for hh = 1:length(H)
    Z0(hh, 1) = 0;
    DL2 = 0.001;
    DU2 = 0.001;
    KBM1 = nlev-1;
    for nn = 1:nlev-1
        X1 = DL2 + DU2;
        X1 = X1 * (KBM1 - nn) / KBM1;
        X1 = X1 - DL2;
        X1 = tanh(X1);
        X2 = tanh(DL2);
        X3 = X2 + tanh(DU2);

        Z0(hh, nn + 1) = ((X1 + X2) / X3) - 1.0;
    end

    % s-coordinates
    X1 = (H(hh) - DU - DL);
    X2 = X1 ./ H(hh);
    DR = X2 ./ (nlev - KU - KL - 1);

    Z2(hh, 1) = 0.0;

    for K = 2:KU + 1
        Z2(hh, K)= Z2(hh, K - 1) - (ZKU(K - 1) ./ H(hh));
    end

    for K = KU + 2:nlev - KL
        Z2(hh, K) = Z2(hh, K - 1) - DR;
    end

    KK = 0;
    for K = nlev - KL + 1:nlev
        KK = KK + 1;
        Z2(hh, K) = Z2(hh, K - 1) - (ZKL(KK) ./ H(hh));
    end
end