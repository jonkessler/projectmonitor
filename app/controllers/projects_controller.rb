class ProjectsController < ApplicationController
  before_filter :authenticate_user!, :except => [:show, :status, :index]
  before_filter :load_project, :only => [:edit, :update, :destroy]
  around_filter :scope_by_aggregate_project

  respond_to :json, only: [:index, :show]

  def index
    if params[:aggregate_project_id].present?
      projects = AggregateProject.find(params[:aggregate_project_id]).projects
    else
      standalone_projects = Project.standalone.displayable(params[:tags])
      aggregate_projects = AggregateProject.displayable(params[:tags])
      projects = standalone_projects + aggregate_projects
    end

    respond_with ProjectFeedDecorator.decorate projects
  end

  def new
    @project = Project.new
  end

  def create
    klass = params[:project][:type].present? ? params[:project][:type].constantize : Project
    @project = klass.create(params[:project])
    if @project.save
      redirect_to edit_configuration_path, notice: 'Project was successfully created.'
    else
      render :new
    end
  end

  def show
    respond_with Project.find(params[:id])
  end

  def update
    if params[:password_changed] != 'true'
      params[:project].delete(:auth_password)
    else
      params[:project][:auth_password] = nil unless params[:project][:auth_password].present?
    end

    Project.transaction do
      if params[:project][:type] && @project.type != params[:project][:type]
        @project = @project.becomes(params[:project][:type].constantize)
        if project = Project.where(id: @project.id)
          project.update_all(type: params[:project][:type])
        end
      end

      if @project.update_attributes(params[:project])
        redirect_to edit_configuration_path, notice: 'Project was successfully updated.'
      else
        render :edit
        raise ActiveRecord::Rollback
      end
    end
  end

  def destroy
    @project.destroy
    redirect_to edit_configuration_path, notice: 'Project was successfully destroyed.'
  end

  def validate_build_info
    project = params[:project][:type].constantize.new(params[:project])

    if existing_project_missing_password?
      existing_project = Project.find(params[:project][:id])
      project.auth_password = existing_project.auth_password if existing_project
    end

    log_entry = ProjectUpdater.update(project)

    render :json => {
      status: log_entry.status == 'successful',
      error_type: log_entry.error_type,
      error_text: log_entry.error_text.to_s[0,10000]
    }
  end

  def validate_tracker_project
    project = Project.find(params[:id])
    status = :accepted
    if project.tracker_validation_status.present? &&
      project.tracker_validation_status[:auth_token] == params[:auth_token] &&
      project.tracker_validation_status[:project_id] == params[:project_id]
      status = project.tracker_validation_status[:status]
    else
      TrackerProjectValidator.delay(priority: 0).validate(params)
      project.tracker_validation_status = {auth_token: params[:auth_token], project_id: params[:project_id], status: :accepted}
      project.save!
    end
    head status
  end

  private

  def load_project
    @project = Project.find(params[:id])
  end

  def scope_by_aggregate_project
    if aggregate_project_id = params[:aggregate_project_id]
      Project.with_aggregate_project aggregate_project_id do
        yield
      end
    else
      yield
    end
  end

  def existing_project_missing_password?
    params[:project][:id].present? && params[:project][:auth_password].empty?
  end
end
