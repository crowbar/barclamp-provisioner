/**
 * Copyright 2011-2013, Dell
 * Copyright 2013-2014, SUSE LINUX Products GmbH
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

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

  $('input[data-name=key]').on('change', function() {
    var hash = md5($(this).val()).substring(0, 8);
    var elm  = $(this.parentElement.parentElement).find('input[data-name=name]');
    elm.val(hash);
  });
});
