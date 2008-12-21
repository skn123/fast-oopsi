function [n_best P_best]=FOOPSI2_5(F,P,Sim)
% this function solves the following optimization problem:
% n_best = argmax_{n >= 0} P(n | F)
% which is a MAP estimate for the most likely spike train given the
% fluorescence signal.  given the model:
%
% n_t ~ Poisson(n_t; p_t)
% C_t = a C_{t-1} + n_t, where a=(1-dt/tau), and A is fixed at 1.
% F_t = C_t + eps_t, eps_t ~ N(mu,sig^2)
%
% and we approx the Poisson with an Exponential yielding
% n_best = argmin_{n: n_t >= 0 forall t} sum_t ((F_t - C_t)^2 + lambda n_t
%
% instead of solving this directly, we iteratively solve
%
% n_eta = argmin sum_t ((F_t - C_t)^2 + lambda n_t -eta*log(n_t)
%
% starting with eta at some reasonably large value, and then decreasing.
% note that -log(n_t) is a "barrier term" which softens the constraints
% mapping the problem into a concave one.  each step with solved in O(T)
% time by utilizing gaussian elimination on the tridiagonal hessian, as
% opposed to the O(T^3) time typically required for non-negative
% deconvolution.
%
% Input----
% F:    fluorescence time series
% P.    structure of neuron parameters
%   tau: time constant size
%   lam: prior weight = 1/(rate*dt)
%   sig: standard deviation of err
%   mu : mean of err
% Sim.  structure of simulation parameters
%   dt      : time step size
%   Plot    : whether to plot results        (if not set, default is no)
%   MaxIter : maximum number of iterations   (typically set to 50)
% Output---
% n_best:    inferred spike train
% P_best:    inferred parameter structure
%
% Remarks on revisions:
% 1_7: no longer need to define Sim.Plot (ie, if it is not defined, default
% is to not plot, but if it is defined, one can either plot or not)
%
% 1_8: cleaned up code from 1_7, and made Identity matrix outside loop,
% which gets diagonal replaced inside loop (instead of calling speye in
% loo)
%
% 1_9: mean subtract and normalize max(F)=1 such that arbitrary scale and
% offset shifts do no change results.
%
% 2: removed normalize.  takes either a row or column vector.
% doesn't require any Sim fields other than Sim.dt. also, we estimate
% parameters now using FastParams code (which is the same as the one used
% to estimate params given the real spikes, for debugging purposes)
%
% 2_1: also estimate mu
% 2_2: forgot to make this one :)
% 2_3: fixed a bunch of bugs.  this version works to infer and learn, but
% fixes mu in above model.
%%
fprintf('\nFOOPSI2_5\n')

% get F "right"
% F       = F - min(F);                       % min subtraction
% F       = F / max(F);                       % normalize so max(F)=1
siz     = size(F);                          % make sure it is a vector
if siz(1)>1 && siz(2) >1
    error('F must be a vector')
elseif siz(1)==1 && siz(2)>1                % make sure it is a column vector
    F=F';
end

% define some stuff for brevity
T       = length(F);                        % number of time steps
dt      = Sim.dt;                           % for brevity
a       = 1 - dt/P.tau;                     % decay factor
c       = 1/(2*P.sig^2);                    % scale of variance
mu      = P.mu;                             % mean of noise

% original parameter estimate
Q.tau   = P.tau;                                
Q.sig   = P.sig;
Q.lam   = P.lam;
Q.mu    = P.mu;

% define some stuff for speed
O       = 1+0*F;                            % init a unity vector
M       = spdiags([-a*O O], -1:0,T,T);      % matrix transforming calcium into spikes, ie n=M*C
I       = speye(T);                         % create out here cuz it must be reused
Hmat1   = 2*c*I;                            % pre-compute matrix for hessian
Hmat2   = I;                                % another one
diags   = 1:T+1:T^2;                        % index of diagonal elements of TxT matrices
offdiags=2:T+1:T^2;                         % index of off-diagonal elements (the diagonal below the diagonal) of TxT matrices

% if we are not estimating parameters
if ~isfield(Sim,'MaxIter') || Sim.MaxIter==0,
    Sim.MaxIter=0;
    [n C]   = FastFilter(F,P);
    n_best  = n;
    P_best  = P;
else
    % initialize some stuff
    n       = O/P.lam;                          % spike train
    C       = filter(1,[1 -(1-dt/P.tau)],n);    % calcium concentratin
    DD      = (F-C-mu)'*(F-C-mu);                     % squared error
    lik     = zeros(1,Sim.MaxIter);             % extize likelihood
    lik(1)  = .5*T*log(2*pi*P.sig^2) + DD/(2*P.sig^2) - T*log(P.lam*dt) + P.lam*sum(n);% initialize likelihood
    minlik  = lik(1);                           % minimum likelihood achived so far

    % prepare stuff for plotting
    if isfield(Sim,'Plot'), DoPlot = Sim.Plot; else DoPlot = 0; end
    if DoPlot == 1
        figure(104), clf
        fprintf('lam=%.2f, tau=%.2f, mu=%.2f, sig=%.2f, lik=%.2f\n',P.lam,P.tau,P.mu,P.sig,lik(1))
    end
end

for i=1:Sim.MaxIter

    [n C]   = FastFilter(F,P);
    P       = FastParams2_4(F,C,n,T,dt);

    lik(i+1) = P.lik;
    if DoPlot == 1
        subplot(311), hold on, plot(i+1,lik(i+1),'o'), axis('tight')
        subplot(312), cla, hold on, plot(F,'.k'), plot(C+P.mu,'b'),  axis('tight')
        subplot(313), cla, bar(n,'EdgeColor','r','FaceColor','r'), axis('tight'), drawnow
        fprintf('lam=%.2f, tau=%.2f, mu=%.2f, sig=%.2f, lik=%.2f\n',P.lam,P.tau,P.mu,P.sig,lik(i+1))
    end

    % the next line of code is only necessary because likelihood
    % doesn't increase with each step
    if lik(i+1)<minlik,
        minlik=lik(i+1); P_best = P; n_best = n;
    end

    % stopping criterion
    if abs(lik(i+1)-lik(i))<1e-3, break, end
end
P_best.i = i;


    function [n C] = FastFilter(F,P)

        eta = 1;                                % weight on barrier function
        a   = 1 - dt/P.tau;                     % decay factor
        c   = 1/(2*P.sig^2);                    % scale of variance
        mu  = P.mu;                             % mean of noise
        n   = O*(eta/P.lam);                    % initialize spike train
        C   = filter(1,[1, -a],n);              % initialize calcium
        M(offdiags) = -a;                       % matrix transforming calcium into spikes, ie n=M*C
        Hmat1(diags)= 2*c;                      % pre-compute matrix for hessian
        sumM        = sum(M)';
        
        while eta>1e-13                         % this is an arbitrary threshold

            D = F-C-mu;                         % difference vector
            L = c*D'*D+P.lam*sum(n)-eta*sum(log(n));  % Likilihood function using C
            s = 1;                              % step size
            d = 1;                              % direction
            while norm(d)>5e-2 && s > 1e-3      % converge for this eta (again, these thresholds are arbitrary)
                g   = -2*c*D + P.lam*sumM - eta*M'*(n.^-1);  % gradient
                Hmat2(diags) = n.^-2;
                H   = Hmat1 + 2*eta*M'*Hmat2*M; % Hessian                
                d   = -H\g;                     % direction to step using newton-raphson
                hit = -n./(M*d);                % step within constraint boundaries
                hit(hit<0)=[];                  % ignore negative hits
                if any(hit<1)
                    s = min(1,0.99*min(hit(hit>0)));
                else
                    s = 1;
                end
                L_new = L+1;
                while L_new>=L+1e-7             % make sure newton step doesn't increase objective
                    C_new   = C+s*d;
                    n       = M*C_new;
                    D       = F-C_new-mu;
                    L_new   = c*D'*D+P.lam*sum(n)-eta*sum(log(n));
                    s       = s/2;              % if step increases objective function, decrease step size
                end

                C = C_new;                      % update C
                L = L_new;                      % update L

            end
            eta=eta/10;                         % reduce eta (sequence of eta reductions is arbitrary)
        end
    end

end