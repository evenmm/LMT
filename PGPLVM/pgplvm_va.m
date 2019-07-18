function result = pgplvm_va(yy,xx,setopt)
% Initialize the log of spike rates with the square root of spike counts.
ffmat = sqrt(yy);

% Get sizes and spike counts
[nt,nneur] = size(yy); % nt: number of time points; nneur: number of neurons
nf = size(xx,2); % number of latent dimensions

%
latentTYPE = setopt.latentTYPE; % kernel for the latent, 1. AR1, 2. SE
ffTYPE = setopt.ffTYPE; % kernel for the tuning curve, 1. AR1, 2. SE
xpldsmat = setopt.xpldsmat;
xplds = setopt.xplds;

% generate grid values as inducing points
tgrid = [1:nt]';
switch nf
    case 1
        xgrid = gen_grid([min(xx(:,1)) max(xx(:,1))],25,nf); % x grid (for plotting purposes)
    case 2
        xgrid = gen_grid([min(xx(:,1)) max(xx(:,1)); min(xx(:,2)) max(xx(:,2))],10,nf); % x grid (for plotting purposes)
end

% set hypers
hypers = [setopt.rhoxx, setopt.lenxx, setopt.rhoff, setopt.lenff]; % rho for Kxx; len for Kxx; rho for Kff; len for Kff

% set initial noise variance for simulated annealing
lr = setopt.lr; % learning rate
sigma2_init = setopt.sigma2_init;
propnoise_init = 0.001;
sigma2 = sigma2_init;
propnoise = propnoise_init;

% set initial prior kernel
% K = Bfun(eye(nt),0)*Bfun(eye(nt),0)';
% Bfun maps the white noise space to xx space
[Bfun, BTfun, nu, sdiag, iikeep, Kprior] = prior_kernel(hypers(1),hypers(2),nt,latentTYPE,tgrid);
rhoxx = hypers(1); % marginal variance of the covariance function the latent xx
lenxx = hypers(2); % length scale of the covariance function for the latent xx
rhoff = hypers(3); % marginal variance of the covariance function for the tuning curve ff
lenff = hypers(4); % length scale of the covariance function for the tuning curve ff

% initialize latent
initTYPE = setopt.initTYPE;
switch initTYPE
    case 1  % use LLE or PPCA or PLDS init
        uu0 = Bfun(xplds,1);
        % uu0 = Bfun(xlle,1);
        % uu0 = Bfun(xppca,1);
    case 2   % use random init
        uu0 = randn(nu,nf)*0.01;
    case 3   % true xx
        uu0 = Bfun(xx,1);
end
uu = uu0;  % initialize sample
xxsamp = Bfun(uu,0);
xxsampmat = align_xtrue(xxsamp,xx);
xxsampmat_old = xxsampmat;

covfun = covariance_fun(rhoff,lenff,ffTYPE); % get the covariance function
cuu = covfun(xgrid,xgrid)+sigma2*eye(size(xgrid,1)); % get K_uu
cuuinv = pdinv(cuu);

[Kuf, dKuf] = covfun(xgrid,xxsamp);
Kuu_uf = cuuinv*Kuf;
Umat = cuu*(Kuu_uf'\ffmat);
Umat = Umat/norm(Umat); % get initial U (function values evaluated at the inducing points)

% Now do inference
infTYPE = 1; % 1 for MAP; 2 for MH sampling; 3 for hmc
ppTYPE = 1; % 1 optimization for ff; 2. sampling for ff
opthyp_flag = 1; % flag for optimizing the hyperparameters

% set options for minfunc
options = [];
options.Method='scg';
options.TolFun=1e-4;
options.MaxIter = 1e1;
options.maxFunEvals = 1e1;
options.Display = 'off';

rs = []; % collect r-squared value for our method
niter = setopt.niter;
clf
for iter = 1:niter
    
    if sigma2>1e-8
        sigma2 = sigma2*lr;  % decrease the noise variance with a learning rate
    end
    
    %% 1. Find optimal ff
    [Bfun, BTfun, nu] = prior_kernel(rhoxx,lenxx,nt,latentTYPE,tgrid);
    covfun = covariance_fun(rhoff,lenff,ffTYPE); % get the covariance function
    cuu = covfun(xgrid,xgrid)+sigma2*eye(size(xgrid,1));
    cuuinv = pdinv(cuu);
    
    lmlifun_poiss = @(U) logmargli_gplvm_se_sor_var(uu,U,yy,Bfun,covfun,sigma2,nf,BTfun,xgrid,cuuinv,2);
    switch ppTYPE
        case 1
            U0 = vec(Umat);
            floss_U = @(U) lmlifun_poiss(U); % negative marginal likelihood
            % DerivCheck(floss_U,U0)
            [Unew, fval] = minFunc(floss_U,U0,options);
        case 2
            % set up MCMC inference
            nsperiter = 10;
            fproprnd_U = @(U)(U+randn(size(U))*0.1); % proposal distribution
            flogpdf_U = @(U)(-lmlifun_poiss(U'));
            
            % ========================================
            U0 = vec(Bfun_cov(Umat,1));
            Unew = mhsample_anqi(U0',nsperiter,'logpdf',flogpdf_U,'proprnd',fproprnd_U,'symmetric',true)';
            Unew = Unew(:,end);
    end
    [L,dL,Unew] = lmlifun_poiss(Unew);
    Umat = Unew; % update Umat
    [Kuf, dKuf] = covfun(xgrid,xxsamp);
    Kuu_uf = cuuinv*Kuf;
    ffmat = Kuu_uf'*cuuinv*Umat; % update ffmat
    
    %% 2. Find optimal latent xx, actually search in u space, xx=K^{1/2}*u
    % negative log-likelihood
    lmlifun = @(u) logmargli_gplvm_se_sor_var(u,Umat,yy,Bfun,covfun,sigma2,nf,BTfun,xgrid,cuuinv,1);
    
    % set up MAP inference
    floss = @(u) lmlifun(vec(u));
    opts = optimset('largescale', 'off', 'maxiter', 15, 'display', 'iter');
    
    % set up MCMC inference (not in use)
    nsperiter = 50;
    fproprnd = @(u)(u+randn(size(u))*propnoise); % proposal distribution
    flogpdf = @(u) -lmlifun(u');
    
    % set up HMC inference, if use HMC, we have to choose the SE kernel
    % which returns grad (not in use)
    flogpdf_grad = @(u) hmc_grad(u,lmlifun);
    
    % ========================================
    switch infTYPE
        case 1, % do MAP infernece
            switch ffTYPE
                case 1 % AR1, fminunc, no grad
                    uunew = fminunc(floss,vec(uu),opts);
                case 2 % SE, minFunc, with grad
                    % DerivCheck(floss,vec(randn(size(uu))))
                    uunew = minFunc(floss,vec(uu),options);
            end
        case 2, % do MCMC
            uunew = mhsample(vec(uu)',nsperiter,'logpdf',flogpdf,'proprnd',fproprnd,'symmetric',true)';
            uunew = uunew(:,end);
        case 3, % do HMC
            options_hmc = foptions;             % Default options vector.
            options_hmc(1) = 1;         % Switch on diagnostics.
            options_hmc(7) = 1;     % Number of steps in trajectory.
            options_hmc(14) = 1;        % Number of Monte Carlo samples returned.
            options_hmc(15) = 10;       % Number of samples omitted at start of chain.
            options_hmc(18) = 0.001;        % Step size.
            
            % hmc('state', 42);
            uunew = hmc(floss, vec(uu)', options_hmc, flogpdf_grad)';
            uunew = uunew(:,end);
    end
    uu = reshape(uunew,[],nf); % update uu
    xxsamp = Bfun(uu,0); % update xx
    
    % plot latent xx
    xxsampmat = align_xtrue(xxsamp,xx);
    switch nf
        case 1
            subplot(212); plot(1:nt,xx,'b-',1:nt,xpldsmat,'m.-',1:nt,xxsampmat,'k-',1:nt,xxsampmat_old,'k:','linewidth',2); drawnow; legend('true x','PLDS x','P-GPLVM x','P-GPLVM old x');
        case 2
            subplot(413); plot(1:nt,xx(:,1),'b-',1:nt,xpldsmat(:,1),'m.-',1:nt,xxsampmat(:,1),'k-',1:nt,xxsampmat_old(:,1),'k:','linewidth',2); drawnow; legend('true x','PLDS x','P-GPLVM x','P-GPLVM old x');
            subplot(414); plot(1:nt,xx(:,2),'b-',1:nt,xpldsmat(:,2),'m.-',1:nt,xxsampmat(:,2),'k-',1:nt,xxsampmat_old(:,2),'k:','linewidth',2); drawnow;
    end
    xxsampmat_old = xxsampmat;
    
    %% optimze hyperparameters
    if opthyp_flag
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % Compute initial negative log-likelihoods
        hypid = setopt.hypid; % 1. rho for Kxx; 2. len for Kxx; 3. rho for Kff; 4. len for Kff; 5. sigma2 (annealing it instead of optimizing it)
        loghyp0 = log([hypers sigma2]);
        loghyp = log([rhoxx;lenxx;rhoff;lenff;sigma2]);
        loghyp = loghyp(hypid);
        lmlifun_hyp = @(loghyp) logmargli_gplvm_se_sor_var_hyp(loghyp,loghyp0,xxsamp,Umat,yy,xgrid,latentTYPE,tgrid,hypid,ffTYPE);
        opts = optimset('largescale', 'off', 'maxiter', 1e1, 'display', 'off');
        lb = [0;2.3;0;-3;-5]; % lower bound
        lb = lb(hypid);
        ub = [5;5;5;5;5]; % upper bound
        ub = ub(hypid);
        loghypnew = fmincon(lmlifun_hyp,vec(loghyp),[],[],[],[],lb,ub,[],opts);
        % loghypnew = fminunc(lmlifun_hyp,vec(loghyp),opts);
        loghyp0new = loghyp0;
        loghyp0new(hypid) = loghypnew;
        rhoxx = exp(loghyp0new(1));
        lenxx = exp(loghyp0new(2));
        rhoff = exp(loghyp0new(3));
        lenff = exp(loghyp0new(4));
        sigma2 = exp(loghyp0new(5));
        display(['iter:' num2str(iter) ', rhoxx:' num2str(rhoxx) ', lenxx:' num2str(lenxx) ', rhoff:' num2str(rhoff) ', lenff:' num2str(lenff) ', sigma2:' num2str(sigma2)])
    end
    
    %% collect r-squared values
    display(['iter:' num2str(iter) ', PLDS r2:' num2str(rsquare(xx,xpldsmat)) ', P-GPLVM r2:' num2str(rsquare(xx,xxsampmat))])
    rs = [rs; rsquare(xx,xxsampmat)];
    subplot(211),hold on,
    plot(rs,'r-')
    plot(rsquare(xx,xpldsmat)*ones(length(rs),1),'b-')
    legend('P-GPLVM','PLDS')
    hold off, title(['r-squared values: iter ' num2str(iter)]),drawnow
    
end

result.xxsamp = xxsamp;
result.xxsampmat = xxsampmat;
result.ffmat = ffmat;
result.rhoxx = rhoxx;
result.lenxx = lenxx;
result.rhoff = rhoff;
result.lenff = lenff;



