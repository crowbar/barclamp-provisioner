$(document).ready(function($) {

  $('#use_serial_console').on('change', function() {
    var value = $(this).val();

    if (value == 'false') {
      $('#serial_tty').attr('disabled', 'disabled');
    }
    else
    {
      $('#serial_tty').removeAttr('disabled');
    }
  }).trigger('change');
});
