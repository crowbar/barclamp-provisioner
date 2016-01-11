def upgrade ta, td, a, d
   a["dhcp"]["state_machine"]["crowbar_upgrade"] = ta["dhcp"]["state_machine"]["crowbar_upgrade"]
  return a, d
end

def downgrade ta, td, a, d
  a["dhcp"]["state_machine"].delete("crowbar_upgrade")
  return a, d
end
