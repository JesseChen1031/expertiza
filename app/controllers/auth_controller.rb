class AuthController < ApplicationController
  include AuthorizationHelper
  helper :auth

  # GETs should be safe (see http://www.w3.org/2001/tag/doc/whenToUseGet.html)
  verify method: :post, only: %i[login logout],
         redirect_to: { action: :list }

  before_filter :create_session_processor



  def action_allowed?
    case params[:action]
    when 'login', 'logout', 'login_failed'
      true
    else
      current_user_has_super_admin_privileges?
    end
  end

  def login
    if request.get?
      @session_processor.clear_session(session)
    else
      user = User.find_by_login(params[:login][:name])
      if user && user.valid_password?(params[:login][:password])
        after_login(user)
      else
        ExpertizaLogger.error LoggerMessage.new(controller_name, '', 'Failed login attempt. Invalid username/password', request)
        flash[:error] = 'Your username or password is incorrect.'
        redirect_to controller: 'password_retrieval', action: 'forgotten'
      end
    end
  end # def login

  # function to handle common functionality for conventional user login and google login
  def after_login(user)
    session[:user] = user
    session[:impersonate] = false
    ExpertizaLogger.info LoggerMessage.new('', user.name, 'Login successful')
    @session_processor.set_current_role(user.role_id, session) # should be an instance of session.rb
    redirect_to controller: AuthHelper.get_home_controller(session[:user]),
                action: AuthHelper.get_home_action(session[:user])
  end

  def login_failed
    flash.now[:error] = 'Your username or password is incorrect.'
    render action: 'forgotten'
  end

  def logout
    ExpertizaLogger.info LoggerMessage.new(controller_name, '', 'Logging out!', request)
    @session_processor.clear_session(session)
    redirect_to '/'
  end

  def create_session_processor
    @session_processor = Session.new
  end

end
