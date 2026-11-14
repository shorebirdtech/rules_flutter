import 'dart:io';

import 'package:test/test.dart';

import '../android_release.dart';

const _storePassword = 'S3cret-store-\u00e9';
const _keyPassword = 'K3y-secret-pass';

/// `keytool -list -v` for an RSA key, as JDK 25 prints it.
const _rsaListing = '''
Alias name: upload
Creation date: Nov 5, 2026
Entry type: PrivateKeyEntry
Certificate chain length: 1
Certificate[1]:
Owner: CN=Upload Key
Issuer: CN=Upload Key
Serial number: 5a1b2c3d
Valid from: Thu Nov 05 10:00:00 PST 2026 until: Mon Mar 23 10:00:00 PST 2054
Certificate fingerprints:
\t SHA1: 01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67
\t SHA256: AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99
Signature algorithm name: SHA384withRSA
Subject Public Key Algorithm: 2048-bit RSA key
Version: 3
''';

String _listingWith(String algorithm) => _rsaListing.replaceFirst(
  'Subject Public Key Algorithm: 2048-bit RSA key',
  'Subject Public Key Algorithm: $algorithm',
);

void main() {
  group('parseProperties', () {
    test('reads the file Flutter documents', () {
      final p = parseProperties(
        'storePassword=abc123\r\n'
        'keyPassword=abc123\r\n'
        'keyAlias=upload\r\n'
        'storeFile=/Users/me/keys/upload-keystore.jks\r\n',
      );
      expect(p, {
        'storePassword': 'abc123',
        'keyPassword': 'abc123',
        'keyAlias': 'upload',
        'storeFile': '/Users/me/keys/upload-keystore.jks',
      });
    });

    test('skips comments and blank lines', () {
      final p = parseProperties('# one\n\n  ! two\n   \na=1\n');
      expect(p, {'a': '1'});
    });

    test('accepts =, : and whitespace separators', () {
      final p = parseProperties('a=1\nb: 2\nc 3\nd  =  4\ne\t:\t5\n');
      expect(p, {'a': '1', 'b': '2', 'c': '3', 'd': '4', 'e': '5'});
    });

    test('keeps spaces inside a value and trailing whitespace', () {
      expect(parseProperties('a=x y  z \n'), {'a': 'x y  z '});
    });

    test('a key may contain escaped separators', () {
      final p = parseProperties(
        r'a\=b=1'
        '\n'
        r'c\:d : 2'
        '\n'
        r'e\ f=3',
      );
      expect(p, {'a=b': '1', 'c:d': '2', 'e f': '3'});
    });

    test('decodes escapes in values', () {
      final p = parseProperties(
        r'a=\u0041\u00e9'
        '\n'
        r'b=x\ty\nz\\w'
        '\n'
        r'c=\#\!\=\:\q',
      );
      expect(p['a'], 'A\u00e9');
      expect(p['b'], 'x\ty\nz\\w');
      expect(p['c'], '#!=:q');
    });

    test('rejects a malformed \\u escape', () {
      expect(
        () => parseProperties(r'a=\u12'),
        throwsA(isA<ReleaseException>()),
      );
    });

    test('joins continued lines, dropping the next line\'s indent', () {
      final p = parseProperties('a=one \\\n    two\\\n  three\nb=2');
      expect(p, {
        'a':
            'one two'
            'three',
        'b': '2',
      });
    });

    test('an even run of backslashes does not continue', () {
      expect(parseProperties('a=x\\\\\nb=2'), {'a': r'x\', 'b': '2'});
    });

    test('a later duplicate wins', () {
      expect(parseProperties('a=1\na=2'), {'a': '2'});
    });

    test('a key with no value is the empty string', () {
      expect(parseProperties('a\nb='), {'a': '', 'b': ''});
    });
  });

  group('SigningConfig.from', () {
    final full = {
      'storePassword': _storePassword,
      'keyPassword': _keyPassword,
      'keyAlias': 'upload',
      'storeFile': '/keys/up.jks',
    };

    for (final key in full.keys) {
      test('names a missing $key', () {
        final p = {...full}..remove(key);
        expect(
          () => SigningConfig.from(p, keyPropertiesPath: '/w/key.properties'),
          throwsA(
            isA<ReleaseException>().having(
              (e) => e.message,
              'message',
              allOf(contains('`$key`'), contains('/w/key.properties')),
            ),
          ),
        );
      });

      test('names an empty $key', () {
        final p = {...full, key: ''};
        expect(
          () => SigningConfig.from(p, keyPropertiesPath: '/w/key.properties'),
          throwsA(
            isA<ReleaseException>().having(
              (e) => e.message,
              'message',
              contains('`$key`'),
            ),
          ),
        );
      });
    }

    test('leaves an absolute storeFile', () {
      final c = SigningConfig.from(
        full,
        keyPropertiesPath: 'k',
        androidAppDir: '/w/android/app',
      );
      expect(c.storeFile, '/keys/up.jks');
      expect(c.keyAlias, 'upload');
    });

    test('resolves a relative storeFile against android/app', () {
      final c = SigningConfig.from(
        {...full, 'storeFile': '../upload.jks'},
        keyPropertiesPath: 'k',
        androidAppDir: '/w/android/app',
      );
      expect(c.storeFile, '/w/android/app/../upload.jks');
    });

    test('refuses a relative storeFile with no app directory', () {
      expect(
        () => SigningConfig.from(
          {...full, 'storeFile': 'up.jks'},
          keyPropertiesPath: 'k',
        ),
        throwsA(
          isA<ReleaseException>().having(
            (e) => e.message,
            'message',
            contains('`storeFile`'),
          ),
        ),
      );
    });
  });

  group('argument builders', () {
    final lists = <String, List<String>>{
      'keytoolListArgs': keytoolListArgs(keystore: '/k.jks', alias: 'upload'),
      'keytoolGenkeyArgs': keytoolGenkeyArgs(
        keystore: '/k.jks',
        alias: 'upload',
        dname: 'CN=Upload Key',
      ),
      'jarsignerSignArgs': jarsignerSignArgs(
        keystore: '/k.jks',
        alias: 'upload',
        sigalg: 'SHA256withRSA',
        unsigned: '/in.aab',
        signedOut: '/out.aab',
      ),
      'jarsignerVerifyArgs': jarsignerVerifyArgs('/out.aab'),
      'printcertArgs': printcertArgs('/out.aab'),
      'bundletoolValidateArgs': bundletoolValidateArgs(
        bundletool: '/b.jar',
        bundle: '/out.aab',
      ),
      'apksignerSignArgs': apksignerSignArgs(
        apksigner: ['/apksigner.jar', '/lib.jar'],
        keystore: '/k.jks',
        alias: 'upload',
        unsigned: '/u.apk',
        signedOut: '/s.apk',
      ),
    };

    test('none contains a password (builders take none)', () {
      for (final MapEntry(:key, :value) in lists.entries) {
        for (final arg in value) {
          expect(arg, isNot(contains(_storePassword)), reason: key);
          expect(arg, isNot(contains(_keyPassword)), reason: key);
        }
      }
    });

    test('keytool, jarsigner read passwords from the environment', () {
      expect(
        lists['keytoolListArgs'],
        containsAllInOrder(['-storepass:env', storePasswordEnv]),
      );
      expect(
        lists['keytoolGenkeyArgs'],
        containsAllInOrder([
          '-storepass:env',
          storePasswordEnv,
          '-keypass:env',
          keyPasswordEnv,
        ]),
      );
      expect(
        lists['jarsignerSignArgs'],
        containsAllInOrder([
          '-storepass:env',
          storePasswordEnv,
          '-keypass:env',
          keyPasswordEnv,
          '-digestalg',
          'SHA-256',
          '-sigalg',
          'SHA256withRSA',
        ]),
      );
    });

    test('apksigner reads passwords from the environment', () {
      expect(
        lists['apksignerSignArgs'],
        containsAllInOrder([
          '--ks-pass',
          'env:$storePasswordEnv',
          '--key-pass',
          'env:$keyPasswordEnv',
        ]),
      );
    });

    test("apksigner keeps the build's 16 KB alignment", () {
      expect(
        lists['apksignerSignArgs'],
        containsAllInOrder([
          '-cp',
          Platform.isWindows
              ? '/apksigner.jar;/lib.jar'
              : '/apksigner.jar:/lib.jar',
          apksignerMainClass,
          'sign',
          '--alignment-preserved',
          'true',
          '--out',
          '/s.apk',
          '/u.apk',
        ]),
      );
    });

    test('verification is not strict', () {
      expect(lists['jarsignerVerifyArgs'], isNot(contains('-strict')));
    });
  });

  group('keytool output', () {
    test('sigalgFor maps RSA, EC and DSA', () {
      expect(sigalgFor(_rsaListing), 'SHA256withRSA');
      expect(
        sigalgFor(_listingWith('256-bit EC (secp256r1) key')),
        'SHA256withECDSA',
      );
      expect(sigalgFor(_listingWith('2048-bit DSA key')), 'SHA256withDSA');
    });

    test('sigalgFor refuses any other algorithm, naming it', () {
      expect(
        () => sigalgFor(_listingWith('255-bit EdDSA key')),
        throwsA(
          isA<ReleaseException>().having(
            (e) => e.message,
            'message',
            contains('EdDSA'),
          ),
        ),
      );
    });

    test('sigalgFor refuses a listing without the line', () {
      expect(() => sigalgFor('nothing'), throwsA(isA<ReleaseException>()));
    });

    test(
      'fingerprintFrom reads the SHA256 line, not SHA1 or the algorithm',
      () {
        expect(
          fingerprintFrom(_rsaListing),
          'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:'
          'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99',
        );
      },
    );

    test('fingerprintsIn counts every signer', () {
      expect(fingerprintsIn('$_rsaListing$_rsaListing'), hasLength(2));
      expect(
        fingerprintsIn('Signature algorithm name: SHA256withRSA'),
        isEmpty,
      );
    });

    test('fingerprintFrom refuses output without one', () {
      expect(() => fingerprintFrom('x'), throwsA(isA<ReleaseException>()));
    });
  });

  group('parseFlags', () {
    test('reads --name=value', () {
      expect(parseFlags(['--output-dir=/o'], {'output-dir'}), {
        'output-dir': '/o',
      });
    });

    test('refuses an unknown flag', () {
      expect(
        () => parseFlags(['--nope=1'], {'output-dir'}),
        throwsA(isA<UsageException>()),
      );
    });
  });
}
