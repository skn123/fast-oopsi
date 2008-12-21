function [n_best P_best]=FOOPSI_v1_7(F,P,Sim)
% this function solves the following optimization problem:
% n_best = argmax_{n >= 0} P(n | F)
% which is a MAP estimate for the most likely spike train given the
% fluorescence signal.  given the model:
% n_t ~ Binomial(n_t; p_t)
% C_t = a C_{t-1} + A n_t, where a=(1-dt/tau), and A is fixed at 1.
% F_t = C_t + eps_t, eps_t ~ N(0,sig^2)
% and a little simplification, we have
% n_best = argmin sum_t ((F_t - C_t)^2 + lambda n_t
% with constraints: n_t>0 forall t, and
%
% instead of solving this directly, we iteratively solve
%
% n_eta = argmin sum_t ((F_t - C_t)^2 + lambda n_t -eta*log(n_t)
%
% starting with eta at some reasonably large value, and then decreasing.
% note that -log(n_t) is a "barrier term" which softens the constraints
% mapping the problem into a concave one.  each step with solved in O(T)
% time by utilizing gaussian elimination on the tridiagonal hessian.
%
% Input----
% F:    fluorescence time series
% P.    structure of neuron parameters
%   tau: time constant size
%   lam: prior weight = 1/(rate*A*dt)
%   sig: standard deviation of err
% Sim.  structure of simulation parameters
%   dt      : time step size
%   T       : number of time steps
%   Plot    : whether to plot results        (typically set to no)
%   MaxIter : maximum number of iterations   (typically set to 50)
% Output---
% n_best:    inferred spike train
% P_best:    inferred parameter structure
%
% note that in this version we assume that we know lambda, so we do not
% estimate it. it also assumes obsevations at every time step. and it
% assumes a 1D input corresponding to the spatially averaged fluorescence
% signal.

fprintf('\nFOOPSI_v1_7\n')
T       = Sim.T;                            % # of time steps
a       = 1 - Sim.dt/P.tau;                 % decay factor
o       = 1+0*F;                            % init a unity vector
M       = spdiags([-a*o o], -1:0,T,T);      % matrix transforming calcium into spikes, ie n=M*C
Tmat    = speye(T);                         % create out here cuz it must be reused
c       = 1/(2*P.sig^2);                    % scale of variance
Hmat    = 2*c*Tmat;                         % Hessian
eta     = 1;                                % weight on barrier function
n       = o*eta/P.lam;                      % spike train
C       = filter(1,[1 -(1-Sim.dt/P.tau)],n);% calcium concentratin
lik     = zeros(1,Sim.MaxIter);             % extize likelihood
err     = zeros(1,Sim.MaxIter);             % extize likelihood
nsum    = zeros(1,Sim.MaxIter);             % extize likelihood
etasum  = zeros(1,Sim.MaxIter);             % extize likelihood
lik(1)  = c*(F-C)'*(F-C)+P.lam*sum(n)-eta*sum(log(n));% initialize likelihood
err(1)  = c*(F-C)'*(F-C);
nsum(1) = P.lam*sum(n);
etasum(1)= -eta*sum(log(n));
minlik  = inf;                              % minimum likelihood achived so far
DoPlot  = isfield(Sim,'Plot');


if DoPlot == 1 && Sim.Plot== 1
    figure(104), clf
    %     subplot(311), hold on, plot(1,lik(1),'o'), axis('tight')
    fprintf('tau=%.2f, sig=%.2f, lam=%.2f, L=%.2f\n',P.tau,P.sig,P.lam,lik(1))
end
D = F-C;
for i=1:Sim.MaxIter

    eta = 1;                                % weight on barrier function
    n=o*(eta/P.lam);
    C=filter(1,[1 -a],n);

    %     if i==2, keyboard, end
    while eta>1e-13                         % this is an arbitrary threshold

        %         oldD = D;
        D = F-C;                            % difference vector
        % n = M*C;                            % get spike train assuming a particular C
        %         if eta<1 && norm(oldD-D)>eps, keyboard, end
        % if any(n<0), keyboard, end
        L = c*D'*D+P.lam*Sim.dt*sum(n)-eta*sum(log(n));  % Likilihood function using C
        s = 1;                              % step size
        d = 1;                              % direction
        while norm(d)>5e-2 && s > 1e-3      % converge for this eta (again, these thresholds are arbitrary)
            %             fprintf('d=%.3f\n',norm(d))
            g   = -2*c*D + P.lam*Sim.dt*sum(M)' - eta*M'*(n.^-1);  % gradient
            H   = Hmat + 2*eta*M'*spdiags(n.^-2,0,T,T)*M; % Hessian
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
                D       = F-C_new;
                L_new   = c*D'*D+P.lam*Sim.dt*sum(n)-eta*sum(log(n));
                s       = s/2;              % if step increases objective function, decrease step size
                %                 fprintf('s=%.3f\n',s),
                %                 keyboard
            end

            C = C_new;                      % update C
            L = L_new;                      % update L

        end
        eta=eta/10;                         % reduce eta (sequence of eta reductions is arbitrary)
    end

    % update tau
    W = C(1:end-1);
    Y = F(2:end)-n(2:end);
    a = W'*Y/(W'*W);
    if a>1, a=1; elseif a<0, a=0; end           % make sure 'a' is within bounds
    M     = spdiags([-a*o o], -1:0,T,T);        % matrix transforming calcium into spikes, ie n=M*C
    P.tau = Sim.dt/(1-a);

    % update sig
    P.sig = sqrt((F-C)'*(F-C)/T);
    c     = 1/(2*P.sig^2);
    Hmat  = 2*c*Tmat;

    %     % update lambda
    %     P.lam = T/(Sim.dt*sum(n));

    lik(i+1) = Sim.T*.5*log(2*pi*P.sig^2) + c*D'*D - Sim.T*log(P.lam*Sim.dt) - P.lam*Sim.dt*sum(n);
    %     P.L(i+1)    = L;
    %     lik(i+1)    = L;
    %     err(i+1)    = c*D'*D;
    %     nsum(i+1)   = P.lam*Sim.dt*sum(n);
    %     etasum(i+1) = -eta*sum(log(n));
    %     fprintf('lik=%.2f, err=%.2f, nsum=%.2f, etasum=%.2f\n',lik(i+1), err(i+1),nsum(i+1), etasum(i+1) )
    if DoPlot == 1 && Sim.Plot== 1
        subplot(311), hold on, plot(i+1,lik(i+1),'o'), axis('tight')
        subplot(312), cla, hold on, plot(F,'.k'), plot(C,'b'),  axis('tight')
        subplot(313), cla, bar(n,'EdgeColor','r','FaceColor','r'), axis('tight'), drawnow
        fprintf('tau=%.2f, sig=%.2f, lam=%.2f, lik=%.2f\n',P.tau,P.sig,P.lam,lik(i+1))
    end

    % the next line of code is only necessary because likelihood
    % doesn't increase with each step
    if lik(i+1)<minlik, minlik=lik(i+1); P_best = P; n_best = n; end
    if lik(i+1)-lik(i)>1e-3, keyboard, end
    if abs(lik(i+1)-lik(i))<1e-3, break, end
end
% figure(7), plot(lik(2:end))