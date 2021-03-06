classdef rgbd_dvo < handle
    % RGBD_DVO Summary of this class goes here
    %   Detailed explanation goes here
    
    % PUBLIC PROPERTIES
    properties
        fixed;                  % fixed (target) point cloud
        moving;                 % moving (source) point cloud
        fixed_image;            % fixed frame intensity image
        imgrad;                 % image intensity gradient
        gradI;                  % intensity gradient
        MAX_ITER = 1000;        % maximum number of iteration
        % The program stops if norm(omega)+norm(v) < eps
        eps = 5*1e-5;
        eps_2 = 1e-5;
        R = eye(3);             % initial orientation 
        T = zeros(3,1);         % initial translation
        omega;                  % so(3) part of twist
        v;                      % R^3 part of twist
        tform;                  % SE(3) tf
        iterations;             % number if iterations performed 
        ids;                    % nonzero indicies of coefficient matrix A
        min_step = 2*1e-1;      % minimum step size foe integration
        step;                   % integration step
        cloud_x;                % target points
        cloud_y;                % source points
        intensity_x;            % target intensity
        intensity_y;            % source intensity
        U;                      % first reprojected coordinates
        V;                      % second reprojected coordinates
        J;                      % Jacobian
        Jtr;                    % J^T * residual
        u_max;                  % maximum horizontal image size
        v_max;                  % maximum vertical image size
        invalid_points;         % invalid points after projection
        Kf;                     % intrinsic matrix of focal lengths
        residual;
        alpha;                  % Cauchy loss parameter
    end
    
    
    methods(Static)
        function Ti = tf_inv(R, t)
            % SE(3) inverse
            Ti = [R', -R' * t; 0, 0, 0, 1];
        end
        
        function d = dist_se3(R, t)
            % se(3) matrix norm

            d = norm(logm([R, t; 0, 0, 0, 1]),'fro');
        end
       
        function omega_hat = hat(omega)
            % The 'hat' function, R^3\to\Skew_3
            omega_hat = [0,         -omega(3),  omega(2);...
                        omega(3),   0,          -omega(1);...
                        -omega(2),  omega(1),   0];
        end
        
        function intensity = rgb2intensity(rgb)
            % convert RGB values to grayscale using MATLAB's rgb2gray
            % coefficients.
            try
           intensity = 0.2989 * rgb(:,1) + 0.5870 * rgb(:,2) + 0.1140 * rgb(:,3);
           if any(intensity > 1)
               intensity = double(intensity) / 255;
           end
            catch
                keyboard;
            end
        end
    end
    
    
    methods
        function obj = rgbd_dvo(varargin)
            % RGBD_DVO Construct an instance of this class
            if nargin == 2
                disp('Initial transformation is set.');
                obj.R = varargin{1};
                obj.T = varargin{2};
            else
                obj.R = eye(3);
                obj.T = zeros(3,1);
            end
            obj.Kf = [];
            obj.tform = affine3d();
        end
        
        function set_ptclouds(obj, target, source, varargin)
            if nargin == 3
                obj.fixed = target.ptcloud;
                if any(target.image > 1)
                    target.image = double(target.image) / 255;
                end
                obj.fixed_image = target.image;
                % compute image intensity gradient
                [obj.imgrad.u, obj.imgrad.v] = imgradientxy(target.image, 'central');
                obj.moving = source;
                obj.cloud_x = double(obj.fixed.Location);
                obj.u_max = size(target.image,2);
                obj.v_max = size(target.image,1);
                obj.intensity_y = obj.rgb2intensity(source.Color);
            else
                error('Provide target and source point clouds as inputs');
            end
        end
        
        function projection(obj)
            %{
            - The color images are stored as 640×480 8-bit RGB images in PNG format.
            - The depth maps are stored as 640×480 16-bit monochrome images in PNG format.
            - The color and depth images are already pre-registered using the OpenNI
            driver from PrimeSense, i.e., the pixels in the color and depth images
            correspond already 1:1.
            - The depth images are scaled by a factor of 5000, i.e., a pixel value
            of 5000 in the depth image corresponds to a distance of 1 meter from the
            camera, 10000 to 2 meter distance, etc. A pixel value of 0 means missing
            value/no data.


            The depth images in our datasets are reprojected into the frame of the color
            camera, which means that there is a 1:1 correspondence between pixels in the
            depth map and the color image.

            The conversion from the 2D images to 3D point clouds works as follows. Note
            that the focal lengths (fx/fy), the optical center (cx/cy), the distortion
            parameters (d0-d4) and the depth correction factor are different for each
            camera. The Python code below illustrates how the 3D point can be computed
            from the pixel coordinates and the depth value:

            fx = 525.0  # focal length x
            fy = 525.0  # focal length y
            cx = 319.5  # optical center x
            cy = 239.5  # optical center y

            factor = 5000 # for the 16-bit PNG files
            # OR: factor = 1 # for the 32-bit float images in the ROS bag files

            for v in range(depth_image.height):
              for u in range(depth_image.width):
                Z = depth_image[v,u] / factor;
                X = (u - cx) * Z / fx;
                Y = (v - cy) * Z / fy;

            Camera          fx      fy      cx      cy      d0      d1      d2      d3      d4
            (ROS default)	525.0	525.0	319.5	239.5	0.0     0.0     0.0     0.0     0.0
            Freiburg 1 RGB	517.3	516.5	318.6	255.3	0.2624	-0.9531	-0.0054	0.0026	1.1633
            Freiburg 2 RGB	520.9	521.0	325.1	249.7	0.2312	-0.7849	-0.0033	-0.0001	0.9172
            Freiburg 3 RGB	535.4	539.2	320.1	247.6	0       0       0       0       0

            For more information see: https://vision.in.tum.de/data/datasets/rgbd-dataset/file_formats
            %}
            
            % RGB intrinsic calibration parameters
%             fx = 525.0;  % focal length x
%             fy = 525.0;  % focal length y
%             cx = 319.5;  % optical center x
%             cy = 239.5;  % optical center y
            
            % MATLB Example
%             fx = 565.0;  % focal length x
%             fy = 568.0;  % focal length y
%             cx = 320;  % optical center x
%             cy = 240;  % optical center y
            
            % Freiburg 1
            fx = 517.3;  % focal length x
            fy = 516.5;  % focal length y
            cx = 318.6;  % optical center x
            cy = 255.3;  % optical center y
            
            % Freiburg 2
%             fx = 520.9;  % focal length x
%             fy = 521.0;  % focal length y
%             cx = 325.1;  % optical center x
%             cy = 249.7;  % optical center y
            
            % Freiburg 3
%             fx = 535.4;  % focal length x
%             fy = 539.2;  % focal length y
%             cx = 320.1;  % optical center x
%             cy = 247.6;  % optical center y
            
            obj.U = obj.cloud_y(:,1) * fx ./ obj.cloud_y(:,3) + cx+1;
            obj.V = obj.cloud_y(:,2) * fy ./ obj.cloud_y(:,3) + cy+1;
            % remove out of frame projected points
            obj.invalid_points = obj.U < 0.5 | obj.U > obj.u_max | obj.V < 0.5 | obj.V > obj.v_max;
            obj.U = round(obj.U);
            obj.U(obj.invalid_points) = [];
            obj.V = round(obj.V);
            obj.V(obj.invalid_points) = [];
            % get projected points intensity
            obj.intensity_x = diag(obj.fixed_image(obj.V, obj.U));
            
            if isempty(obj.Kf)
                % [fx 0; 0 fy] * (1/x3) * [1 0 -x1/x3; 0 1 -x2/x3]
                obj.Kf = @(x) [fx/x(3), 0    , -(fx*x(1))/x(3)^2;
                               0    , fy/x(3), -(fy*x(2))/x(3)^2];
            end
            if any(obj.intensity_x > 1)
                obj.intensity_x = double(obj.intensity_x)/255;
            end
            obj.residual = obj.intensity_x - obj.intensity_y(~obj.invalid_points);
        end
        
        function compute_gradient(obj)
            % Computes gradient of photometric error wrt to the rigid tf
            % parameter.
            % first project the transformed points to the fixed frame and
            % re-project them to the image.
            obj.projection();
            
            % get projected points intensity gradient
            obj.gradI = [];
            obj.gradI.u = diag(obj.imgrad.u(obj.V, obj.U));
            obj.gradI.v = diag(obj.imgrad.v(obj.V, obj.U));
            
            obj.J = zeros(6,6);
            obj.Jtr = zeros(6,1);
            x = obj.cloud_y(~obj.invalid_points, :);
%             wi = 1;
            for i = 1:size(x,1)
                Jc = obj.Kf(x(i,:)) * [eye(3), -obj.hat(x(i,:))];
                A = [obj.gradI.u(i), obj.gradI.v(i)] * Jc; 
                obj.J = obj.J + A' * A;
                obj.Jtr = obj.Jtr - A' * obj.residual(i);
            end
        end
        
        function align(obj)
            % Aligns two RGBD point clouds
            obj.R = obj.tform.T(1:3,1:3)';
            obj.T = obj.tform.T(4,1:3)';
            for k = 1:obj.MAX_ITER
                % construct omega and v
                % The point clouds are fixed (x) and moving (y)
                % current transformation
                obj.tform = affine3d([obj.R, obj.T; 0, 0, 0, 1]');
                moved = pctransform(obj.moving, obj.tform);
                
                % extract point cloud information:
                obj.cloud_y = double(moved.Location);
                
                % compute Jacobian
                obj.compute_gradient();
                
                % compute step size for integrating the flow
%                 obj.compute_step_size;
%                 dt = obj.step;
                dt = 0.1;
                twist = dt * obj.J \ obj.Jtr;
                obj.v = twist(1:3);
                obj.omega = twist(4:6);
                
                % Stop if the step size is too small
                if max(norm(obj.omega),norm(obj.v)) < obj.eps
                    break;
                end
                
                % Integrating
                th = norm(obj.omega); homega = obj.hat(obj.omega); 
                dR = eye(3) + (sin(dt * th) / th) * homega + ...
                    ((1 - cos(dt * th)) / th^2) * homega^2;
                dT = (dt * eye(3) + ...
                    (1-cos(dt * th)) / (th^2) * homega + ...
                    ((dt * th - sin(dt * th)) / th^3) * homega^2) * obj.v;
%                 R_new = obj.R * dR;
%                 T_new = obj.R * dT + obj.T;
                R_new = dR * obj.R;
                T_new = dR * obj.T + dT;
                
                % Update the state
                obj.R = R_new;
                obj.T = T_new;
                
                % Our other break
                if obj.dist_se3(dR,dT) < obj.eps_2
                    break;
                end
                
                    disp([k,max(norm(obj.omega),norm(obj.v)),obj.eps,obj.dist_se3(dR,dT),obj.eps_2]);
                
            end
            
            obj.tform = affine3d([obj.R, obj.T; 0, 0, 0, 1]');
%             obj.tform = affine3d(obj.tf_inv(obj.R, obj.T)');
            obj.iterations = k;
        end
    end
end

