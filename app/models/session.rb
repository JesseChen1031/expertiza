class Session < ActiveRecord::SessionStore::Session

  def clear_session(session)
    session[:user_id] = nil
    session[:user] = nil
    session[:credentials] = nil
    session[:menu] = nil
    session[:clear] = true
    session[:assignment_id] = nil
    session[:original_user] = nil
    session[:impersonate] = nil
  end


  def set_current_role(role_id, session)
    if role_id
      role = Role.find(role_id)
      if role
        Role.rebuild_cache if !role.cache || !role.cache.try(:has_key?, :credentials)
        session[:credentials] = role.cache[:credentials]
        session[:menu] = role.cache[:menu]
        ExpertizaLogger.info "Logging in user as role #{session[:credentials].class}"
      else
        ExpertizaLogger.error 'Something went seriously wrong with the role.'
      end
    end
  end

  def clear_user_info(session, assignment_id)
    session[:user_id] = nil
    session[:user] = '' # sets user to an empty string instead of nil, to show that the user was logged in
    role = Role.student
    if role
      Role.rebuild_cache if !role.cache || !role.cache.key?(:credentials)
      session[:credentials] = role.cache[:credentials]
      session[:menu] = role.cache[:menu]
    end
    session[:clear] = true
    session[:assignment_id] = assignment_id
    session[:original_user] = nil
    session[:impersonate] = nil
  end

end
