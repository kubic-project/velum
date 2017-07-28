# frozen_string_literal: true
require "rails_helper"

describe Minion do
  it { is_expected.to validate_uniqueness_of(:minion_id) }

  # rubocop:disable RSpec/ExampleLength
  describe ".assign_roles" do
    let(:minions) do
      described_class.create! [
        { minion_id: SecureRandom.hex, fqdn: "master.example.com" },
        { minion_id: SecureRandom.hex, fqdn: "worker0.example.com" },
        { minion_id: SecureRandom.hex, fqdn: "worker1.example.com" }
      ]
    end

    context "when a master role cannot be assigned remotely" do
      before do
        minions
      end

      it "returns a hash with the master fqdn false" do
        # rubocop:disable RSpec/AnyInstance
        allow_any_instance_of(described_class).to receive(:assign_role)
          .with(:master, remote: true).and_return(false)
        allow_any_instance_of(described_class).to receive(:assign_role)
          .with(:worker, remote: true).and_return(true)
        # rubocop:enable RSpec/AnyInstance
        expect(
          described_class.assign_roles(
            roles:  {
              master: [described_class.first.id],
              worker: described_class.all[1..-1].map(&:id)
            },
            remote: true
          )
        ).to eq(
          minions[0].minion_id => false,
          minions[1].minion_id => true,
          minions[2].minion_id => true
        )
      end
    end

    context "when a minion role cannot be assigned remotely" do
      before do
        minions
      end

      it "returns a hash with the minion fqdns false" do
        # rubocop:disable RSpec/AnyInstance
        allow_any_instance_of(described_class).to receive(:assign_role)
          .with(:master, remote: true).and_return(true)
        allow_any_instance_of(described_class).to receive(:assign_role)
          .with(:worker, remote: true).and_return(false)
        # rubocop:enable RSpec/AnyInstance
        expect(
          described_class.assign_roles(
            roles:  {
              master: [described_class.first.id],
              worker: described_class.all[1..-1].map(&:id)
            },
            remote: true
          )
        ).to eq(
          minions[0].minion_id => true,
          minions[1].minion_id => false,
          minions[2].minion_id => false
        )
      end
    end

    context "when a default role cannot be assigned remotely" do
      before do
        minions
      end

      it "returns a hash with the default_role fqdn false" do
        # rubocop:disable RSpec/AnyInstance
        allow_any_instance_of(described_class).to receive(:assign_role)
          .with(:master, remote: true).and_return(true)
        allow_any_instance_of(described_class).to receive(:assign_role)
          .with(:worker, remote: true).and_return(true)
        allow_any_instance_of(described_class).to receive(:assign_role)
          .with(:another_role, remote: true).and_return(false)
        # rubocop:enable RSpec/AnyInstance
        expect(
          described_class.assign_roles(
            roles: {
              master: [described_class.first.id],
              worker: [described_class.second.id],
            }, default_role: :another_role, remote: true
          )
        ).to eq(
          minions[0].minion_id => true,
          minions[1].minion_id => true,
          minions[2].minion_id => false
        )
      end
    end

    context "when default_role is set" do
      before do
        minions
      end

      it "assigns the default role to the rest of the available minions" do
        described_class.assign_roles(
          roles:        {
            master: [described_class.first.id]
          },
          default_role: :worker
        )

        expect(described_class.all.map(&:role).sort).to eq(["master",
                                                            "worker",
                                                            "worker"])
      end
    end

    context "when default_role is not set" do
      before do
        minions
      end

      it "assigns the minion role to the rest of the available minions" do
        described_class.assign_roles(
          roles: {
            master: [described_class.first.id],
            worker: described_class.all[1..-1].map(&:id)
          }
        )

        expect(described_class.all.map(&:role)).to eq(["master", "worker", "worker"])
      end
    end

    context "when explicit worker role is set" do
      before do
        minions
      end

      it "assigns the worker role to specific minions" do
        described_class.assign_roles(
          roles: {
            master: [described_class.first.id],
            worker: described_class.all[1..-1].map(&:id)
          }
        )

        expect(described_class.all.last.role).to eq("worker")
      end
    end

    it "returns a hash of the minions that were assigned a role" do
      minions
      roles = described_class.assign_roles(
        roles: { master: [described_class.first.id], worker: described_class.all[1..-1].map(&:id) }
      )

      expect(roles).to eq(
        minions[0].minion_id => true,
        minions[1].minion_id => true,
        minions[2].minion_id => true
      )
    end
  end

  context "with some roles assigned" do
    let(:minion) { create(:minion, role: described_class.roles[:master]) }

    it "returns true when calling assign_role" do
      expect(minion.assign_role(:worker)).to be true
    end

    it "updates the role in the database" do
      minion.assign_role :worker
      expect(minion.role).to eq("worker")
    end
  end

  context "with no roles assigned" do
    let(:minion) { create(:minion, role: nil) }

    before { allow(minion.salt).to receive(:assign_role) { true } }

    it "returns true when calling assign_role" do
      expect(minion.reload.assign_role(:master)).to be true
    end

    it "updates the role in the database" do
      minion.assign_role(:master)
      expect(minion.reload.role).to eq("master")
    end

    it "updates the highstate column to 'pending' in the database" do
      minion.update!(highstate: :applied)
      expect { minion.assign_role(:master) }
        .to change { minion.reload.highstate }.from("applied")
        .to("pending")
    end

    context "role fails to be assigned on the remote" do
      before do
        allow(minion.salt).to receive(:assign_role) do
          raise Velum::SaltApi::SaltConnectionException
        end
      end

      it "does not save the role in the database" do
        expect(minion.assign_role(:master, remote: true)).to be false
        expect(minion.reload.role).to be_nil
      end
    end
  end

  describe "computed_status" do
    it "computes unknown if all fields are empty" do
      needed = [{ "admin" => "" }]
      failed = [{ "admin" => "" }]
      expect(described_class.computed_status("admin", needed, failed)).to(
        eq described_class.statuses[:unknown]
      )
    end

    it "computes needed if is set to true" do
      needed = [{ "admin" => true }]
      failed = [{ "admin" => "" }]
      expect(described_class.computed_status("admin", needed, failed)).to(
        eq described_class.statuses[:update_needed]
      )
    end

    it "computes failed if is set to true" do
      needed = [{ "admin" => "" }]
      failed = [{ "admin" => true }]
      expect(described_class.computed_status("admin", needed, failed)).to(
        eq described_class.statuses[:update_failed]
      )
    end

    it "computes failed if is set to true, even if needed is also true" do
      needed = [{ "admin" => true }]
      failed = [{ "admin" => true }]
      expect(described_class.computed_status("admin", needed, failed)).to(
        eq described_class.statuses[:update_failed]
      )
    end
  end
  # rubocop:enable RSpec/ExampleLength
end
