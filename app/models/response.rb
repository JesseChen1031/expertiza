require 'analytic/response_analytic'
require 'lingua/en/readability'

class Response < ActiveRecord::Base
  # Added for E1973. A team review will have a lock on it so only one user at a time may edit it.
  include Lockable
  include ResponseAnalytic
  belongs_to :response_map, class_name: 'ResponseMap', foreign_key: 'map_id', inverse_of: false
  
  has_many :scores, class_name: 'Answer', foreign_key: 'response_id', dependent: :destroy, inverse_of: false
  # TODO: change metareview_response_map relationship to belongs_to
  has_many :metareview_response_maps, class_name: 'MetareviewResponseMap', foreign_key: 'reviewed_object_id', dependent: :destroy, inverse_of: false
  alias map response_map
  attr_accessor :difficulty_rating
  delegate :questionnaire, :reviewee, :reviewer, to: :map

  def response_id
    id
  end

  def display_as_html(prefix = nil, count = nil, _file_url = nil, show_tags = nil, current_user = nil)
    identifier = ""
    # The following three lines print out the type of rubric before displaying
    # feedback.  Currently this is only done if the rubric is Author Feedback.
    # It doesn't seem necessary to print out the rubric type in the case of
    # a ReviewResponseMap.
    identifier += "<h3>Feedback from author</h3>" if self.map.type.to_s == 'FeedbackResponseMap'
    if prefix # has prefix means view_score page in instructor end
      self_id = prefix + '_' + self.id.to_s
      code = construct_instructor_html identifier, self_id, count
    else # in student end
      self_id = self.id.to_s
      code = construct_student_html identifier, self_id, count
    end
    code = construct_review_response code, self_id, show_tags, current_user
    code.html_safe
  end

  # Computes the total score awarded for a review
  def aggregate_questionnaire_score
    # only count the scorable questions, only when the answer is not nil
    # we accept nil as answer for scorable questions, and they will not be counted towards the total score
    sum = 0
    scores.each do |s|
      question = Question.find(s.question_id)
      # For quiz responses, the weights will be 1 or 0, depending on if correct
      sum += s.answer * question.weight unless s.answer.nil? || !question.is_a?(ScoredQuestion)
    end
    sum
  end

  def delete
    self.scores.each(&:destroy)
    self.destroy
  end

  # bug fixed
  # Returns the average score for this response as an integer (0-100)
  def average_score
    unless maximum_score.zero?
      ((aggregate_questionnaire_score.to_f / maximum_score.to_f) * 100).round
    else
      "N/A"
    end
  end

  # Returns the maximum possible score for this response
  def maximum_score
    # only count the scorable questions, only when the answer is not nil (we accept nil as
    # answer for scorable questions, and they will not be counted towards the total score)
    total_weight = 0
    scores.each do |s|
      question = Question.find(s.question_id)
      total_weight += question.weight unless s.answer.nil? || !question.is_a?(ScoredQuestion)
    end
    questionnaire = if scores.empty?
                      questionnaire_by_answer(nil)
                    else
                      questionnaire_by_answer(scores.first)
                    end
    total_weight * questionnaire.max_question_score
  end

  # only two types of responses more should be added
  def email(partial = "new_submission")
    defn = {}
    defn[:body] = {}
    defn[:body][:partial_name] = partial
    response_map = ResponseMap.find map_id
    participant = Participant.find(response_map.reviewer_id)
    # parent is used as a common variable name for either an assignment or course depending on what the questionnaire is associated with
    parent = if response_map.survey?
               response_map.survey_parent
             else
               Assignment.find(participant.parent_id)
             end
    defn[:subject] = "A new submission is available for " + parent.name
    response_map.email(defn, participant, parent)
  end

  # This populate_new_response method returns a Response object used to populate the
  # @response instance object with the correct response according to the rubric review round
  # or with a new Response object that the controller can use
  # this method is called within the new method in response_controller
  def populate_new_response(response_map, current_round)
    response = Response.where(map_id: response_map.id, round: current_round.to_i).order(updated_at: :desc).first
    reviewee_team = AssignmentTeam.find_by(id: response_map.reviewee_id)

    most_recent_submission_by_reviewee = reviewee_team.most_recent_submission if reviewee_team

    if response.nil? || (most_recent_submission_by_reviewee && most_recent_submission_by_reviewee.updated_at > response.updated_at)
      response = Response.create(map_id: response_map.id, additional_comment: '', round: current_round, is_submitted: 0)
    end
    response
  end

  def questionnaire_by_answer(answer)
    unless answer.nil? # for all the cases except the case that  file submission is the only question in the rubric.
      questionnaire = Question.find(answer.question_id).questionnaire
    else
      # there is small possibility that the answers is empty: when the questionnaire only have 1 question and it is a upload file question
      # the reason is that for this question type, there is no answer record, and this question is handled by a different form
      map = ResponseMap.find(self.map_id)
      # E-1973 either get the assignment from the participant or the map itself
      if map.is_a? ReviewResponseMap
        assignment = map.assignment
      else
        assignment = Participant.find(map.reviewer_id).assignment
      end
      topic_id = SignedUpTeam.find_by(team_id: map.reviewee_id).topic_id
      questionnaire = Questionnaire.find(assignment.review_questionnaire_id)
    end
    questionnaire
  end

  def self.concatenate_all_review_comments(assignment_id, reviewer_id)
    comments = ''
    counter = 0
    @comments_in_round = []
    @counter_in_round = []
    assignment = Assignment.find(assignment_id)
    question_ids = Question.get_all_questions_with_comments_available(assignment_id)

    ReviewResponseMap.where(reviewed_object_id: assignment_id, reviewer_id: reviewer_id).find_each do |response_map|
      (1..assignment.num_review_rounds+1).each do |round|
        @comments_in_round[round] = ''
        @counter_in_round[round] = 0
        last_response_in_current_round = response_map.response.select {|r| r.round == round }.last
        next if last_response_in_current_round.nil?
        last_response_in_current_round.scores.each do |answer|
          comments += answer.comments if question_ids.include? answer.question_id
          @comments_in_round[round] += (answer.comments ||= '')
        end
        additional_comment = last_response_in_current_round.additional_comment
        comments += additional_comment
        counter += 1
        @comments_in_round[round] += additional_comment
        @counter_in_round[round] += 1
      end
    end
    [comments, counter, @comments_in_round, @counter_in_round]
  end

  def self.volume_of_review_comments(assignment_id, reviewer_id)
    comments, counter,
      @comments_in_round, @counter_in_round = Response.concatenate_all_review_comments(assignment_id, reviewer_id)
    num_rounds = @comments_in_round.count - 1 #ignore nil element (index 0)

    overall_avg_vol = (Lingua::EN::Readability.new(comments).num_words / (counter.zero? ? 1 : counter)).round(0)
    review_comments_volume = []
    review_comments_volume.push(overall_avg_vol)
    (1..num_rounds).each do |round|
      num = Lingua::EN::Readability.new(@comments_in_round[round]).num_words
      den = (@counter_in_round[round].zero? ? 1 : @counter_in_round[round])
      avg_vol_in_round = (num / den).round(0)
      review_comments_volume.push(avg_vol_in_round)
    end
    review_comments_volume
  end

  # compare the current response score with other scores on the same artifact, and test if the difference
  # is significant enough to notify instructor.
  # Precondition: the response object is associated with a ReviewResponseMap
  ### "map_class.get_assessments_for" method need to be refactored
  def significant_difference?
    map_class = self.map.class
    existing_responses = map_class.get_assessments_for(self.map.reviewee)
    average_score_on_same_artifact_from_others, count = Response.avg_scores_and_count_for_prev_reviews(existing_responses, self)
    # if this response is the first on this artifact, there's no grade conflict
    return false if count.zero?
    # This score has already skipped the unfilled scorable question(s)
    score = aggregate_questionnaire_score.to_f / maximum_score
    questionnaire = questionnaire_by_answer(self.scores.first)
    assignment = self.map.assignment
    assignment_questionnaire = AssignmentQuestionnaire.find_by(assignment_id: assignment.id, questionnaire_id: questionnaire.id)
    # notification_limit can be specified on 'Rubrics' tab on assignment edit page.
    allowed_difference_percentage = assignment_questionnaire.notification_limit.to_f
    # the range of average_score_on_same_artifact_from_others and score is [0,1]
    # the range of allowed_difference_percentage is [0, 100]
    (average_score_on_same_artifact_from_others - score).abs * 100 > allowed_difference_percentage
  end

  def self.avg_scores_and_count_for_prev_reviews(existing_responses, current_response)
    scores_assigned = []
    count = 0
    existing_responses.each do |existing_response|
      unless existing_response.id == current_response.id # the current_response is also in existing_responses array
        count += 1
        scores_assigned << existing_response.aggregate_questionnaire_score.to_f / existing_response.maximum_score
      end
    end
    [scores_assigned.sum / scores_assigned.size.to_f, count]
  end

  # This method returns references to a calibration response, review response, assignment, and questions
  # This method is used within show_calibration_results_for_student when a student views their calibration results for a particular review/assignment.
  def self.calibration_results_info(calibration_id, response_id, assignment_id)
    calibration_response_map = ReviewResponseMap.find(calibration_id)
    review_response_map = ReviewResponseMap.find(response_id)
    calibration_response = calibration_response_map.response[0]
    review_response = review_response_map.response[0]
    questions = AssignmentQuestionnaire.find_by(["assignment_id = ? and questionnaire_id IN (?)",Assignment.find(assignment_id).id, ReviewQuestionnaire.select("id")])
                                       .questionnaire.questions.reject {|q| q.is_a?(QuestionnaireHeader) }

    [calibration_response, review_response, questions]
  end

  def notify_instructor_on_difference
    response_map = self.map
    reviewer_participant_id = response_map.reviewer_id
    reviewer_participant = AssignmentParticipant.find(reviewer_participant_id)
    reviewer_name = User.find(reviewer_participant.user_id).fullname
    reviewee_team = AssignmentTeam.find(response_map.reviewee_id)
    reviewee_participant = reviewee_team.participants.first # for team assignment, use the first member's name.
    reviewee_name = User.find(reviewee_participant.user_id).fullname
    assignment = Assignment.find(reviewer_participant.parent_id)
    Mailer.notify_grade_conflict_message(
      to: assignment.instructor.email,
      subject: 'Expertiza Notification: A review score is outside the acceptable range',
      body: {
        reviewer_name: reviewer_name,
        type: 'review',
        reviewee_name: reviewee_name,
        new_score: aggregate_questionnaire_score.to_f / maximum_score,
        assignment: assignment,
        conflicting_response_url: 'https://expertiza.ncsu.edu/response/view?id=' + response_id.to_s,
        summary_url: 'https://expertiza.ncsu.edu/grades/view_team?id=' + reviewee_participant.id.to_s,
        assignment_edit_url: 'https://expertiza.ncsu.edu/assignments/' + assignment.id.to_s + '/edit'
      }
    ).deliver_now
  end

  # Check if this review was done by TA/instructor return True or False
  def done_by_staff_participant?
    role = Role.find(User.find(Participant.find(ResponseMap.find(Response.find(self.id).map_id).reviewer_id).user_id).role_id).name
    return (role == "Instructor") || (role == "Teaching Assistant")
  end

  private

  def construct_instructor_html identifier, self_id, count
    identifier += '<h4><B>Review ' + count.to_s + '</B></h4>'
    identifier += '<B>Reviewer: </B>' + self.map.reviewer.fullname + ' (' + self.map.reviewer.name + ')'
    identifier + '&nbsp;&nbsp;&nbsp;<a href="#" name= "review_' + self_id + 'Link" onClick="toggleElement(' \
           "'review_" + self_id + "','review'" + ');return false;">hide review</a><BR/>'
  end

  def construct_student_html identifier, self_id, count
    identifier += '<table width="100%">'\
						 '<tr>'\
						 '<td align="left" width="70%"><b>Review ' + count.to_s + '</b>&nbsp;&nbsp;&nbsp;'\
						 '<a href="#" name= "review_' + self_id + 'Link" onClick="toggleElement(' + "'review_" + self_id + "','review'" + ');return false;">hide review</a>'\
						 '</td>'\
						 '<td align="left"><b>Last Reviewed:</b>'\
						 "<span>#{(self.updated_at.nil? ? 'Not available' : self.updated_at.strftime('%A %B %d %Y, %I:%M%p'))}</span></td>"\
						 '</tr></table>'
  end

  def construct_review_response code, self_id, show_tags = nil, current_user = nil
    code += '<table id="review_' + self_id + '" class="table table-bordered">'
    answers = Answer.where(response_id: self.response_id)
    unless answers.empty?
      questionnaire = self.questionnaire_by_answer(answers.first)
      questionnaire_max = questionnaire.max_question_score
      questions = questionnaire.questions.sort_by(&:seq)
      # get the tag settings this questionnaire
      tag_prompt_deployments = show_tags ? TagPromptDeployment.where(questionnaire_id: questionnaire.id, assignment_id: self.map.assignment.id) : nil
      code = add_table_rows questionnaire_max, questions, answers, code, tag_prompt_deployments, current_user
    end
    comment = unless self.additional_comment.nil?
                self.additional_comment.gsub('^p', '').gsub(/\n/, '<BR/>')
              else
                ''
              end
    code += '<tr><td><b>Additional Comment: </b>' + comment + '</td></tr>'
    code += '</table>'
  end

  def add_table_rows questionnaire_max, questions, answers, code, tag_prompt_deployments = nil, current_user = nil
    count = 0
    # loop through questions so the the questions are displayed in order based on seq (sequence number)
    questions.each do |question|
      count += 1 if !question.is_a? QuestionnaireHeader and question.break_before == true
      answer = answers.find {|a| a.question_id == question.id }
      row_class = count.even? ? "info" : "warning"
      row_class = "" if question.is_a? QuestionnaireHeader
      code += '<tr class="' + row_class + '"><td>'
      if !answer.nil? or question.is_a? QuestionnaireHeader
        code += if question.instance_of? Criterion
                  # Answer Tags are enabled only for Criterion questions at the moment.
                  question.view_completed_question(count, answer, questionnaire_max, tag_prompt_deployments, current_user) || ''
                elsif question.instance_of? Scale
                  question.view_completed_question(count, answer, questionnaire_max) || ''
                else
                  question.view_completed_question(count, answer) || ''
                end
      end
      code += '</td></tr>'
    end
    code
  end

  # Computes the total score for a *list of assessments*
  # parameters
  #  assessments - a list of assessments of some type (e.g., author feedback, teammate review)
  #  questions - the list of questions that was filled out in the process of doing those assessments
  def self.compute_scores(assessments, questions)
    scores = {}
    if assessments.present?
      scores[:max] = -999_999_999
      scores[:min] = 999_999_999
      total_score = 0
      length_of_assessments = assessments.length.to_f
      assessments.each do |assessment|
        curr_score = assessment_score(response: [assessment], questions: questions)

        scores[:max] = curr_score if curr_score > scores[:max]
        scores[:min] = curr_score unless curr_score >= scores[:min] || curr_score == -1

        # Check if the review is invalid. If is not valid do not include in score calculation
        if @invalid == 1 || curr_score == -1
          length_of_assessments -= 1
          curr_score = 0
        end
        total_score += curr_score
      end
      scores[:avg] = unless length_of_assessments.zero?
                       total_score.to_f / length_of_assessments
                     else
                       0
                     end
    else
      scores[:max] = nil
      scores[:min] = nil
      scores[:avg] = nil
    end

    scores
  end

  # Computes the total score for an assessment
  # params
  #  assessment - specifies the assessment for which the total score is being calculated
  #  questions  - specifies the list of questions being evaluated in the assessment

  def self.assessment_score(params)
    @response = params[:response].last
    return -1.0 if @response.nil? 
    if @response
      @questions = params[:questions]
      return -1.0 if @questions.nil? 
      weighted_score = 0
      sum_of_weights = 0
      max_question_score = 0

      @questionnaire = Questionnaire.find(@questions.first.questionnaire_id) 

      # Retrieve data for questionnaire (max score, sum of scores, weighted scores, etc.)
      questionnaire_data = ScoreView.questionnaire_data(@questions[0].questionnaire_id, @response.id)
      weighted_score = questionnaire_data.weighted_score.to_f unless questionnaire_data.weighted_score.nil?
      sum_of_weights = questionnaire_data.sum_of_weights.to_f
      answers = Answer.where(response_id: @response.id)
      answers.each do |answer|
        question = Question.find(answer.question_id)
        if answer.answer.nil? && question.is_a?(ScoredQuestion)
          sum_of_weights -= Question.find(answer.question_id).weight
        end
      end
      max_question_score = questionnaire_data.q1_max_question_score.to_f
      if sum_of_weights > 0 && max_question_score && weighted_score > 0
        return (weighted_score / (sum_of_weights * max_question_score)) * 100
      else
        return -1.0 # indicating no score
      end
    end
  end
end