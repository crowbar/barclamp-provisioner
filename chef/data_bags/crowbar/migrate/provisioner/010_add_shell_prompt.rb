def upgrade ta, td, a, d
  a["shell_prompt"] = ta["shell_prompt"]
  return a, d
end

def downgrade ta, td, a, d
  a.delete("shell_prompt")
  return a, d
end
