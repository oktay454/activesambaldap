require 'asl-test-utils'

class AslUserShowTest < Test::Unit::TestCase
  include AslTestUtils

  def setup
    super
    @command = File.join(@bin_dir, "asl-usershow")
  end

  def test_exist_user
    make_dummy_user do |user, password|
      user.class.setup_connection("reference")
      begin
        user = user.class.find(user.uid)
        assert_equal([true, user.to_ldif, ""], run_command(user.uid))
      ensure
        user.class.setup_connection("update")
      end
    end
  end

  def test_not_exist_user
    assert_equal([false, "", _("user doesn't exist: %s") % 'not-exist' + "\n"],
                 run_command("not-exist"))
  end
end
