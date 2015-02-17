def upgrade ta, td, a, d
  a['enable_pxe'] = ta['enable_pxe']
  return a, d
end

def downgrade ta, td, a, d
  a.delete('enable_pxe')
  return a, d
end
