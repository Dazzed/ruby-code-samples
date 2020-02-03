require 'rails_helper'

RSpec.describe GuessGameChoice, type: :model do
  describe 'db columns' do
    it { expect(subject).to have_db_column :id }
    it { expect(subject).to have_db_column :guess_game_question_id }
    it { expect(subject).to have_db_column :text }
    it { expect(subject).to have_db_column :hidden }
    it { expect(subject).to have_db_column :created_at }
    it { expect(subject).to have_db_column :updated_at }
    it { expect(subject).to have_db_column :my_text }
  end

  context "relationships" do
    it { expect(subject).to have_many(:answers) }
    it { expect(subject).to belong_to(:question) }
  end
end
