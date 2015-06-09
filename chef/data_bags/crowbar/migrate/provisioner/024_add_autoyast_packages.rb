def upgrade ta, td, a, d
  a['packages'] ||= {}
  return a, d
end

def downgrade ta, td, a, d
  a.delete('packages')
  return a, d
end
