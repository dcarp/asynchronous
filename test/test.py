#! /usr/bin/env python3

import asyncio
import unittest

class TestAsyncio(unittest.TestCase):

	def test_get_event_loop(self):
		loop = asyncio.get_event_loop()
		assert(loop is not None)

if __name__ == '__main__':
    unittest.main()